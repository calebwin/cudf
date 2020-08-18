/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/ast/ast.cuh>
#include <cudf/ast/linearizer.hpp>
#include <cudf/ast/operators.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/scalar/scalar.hpp>
#include <cudf/scalar/scalar_device_view.cuh>
#include <cudf/table/table.hpp>
#include <cudf/table/table_device_view.cuh>
#include <cudf/table/table_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/error.hpp>
#include <cudf/utilities/traits.hpp>
#include <cudf/utilities/type_dispatcher.hpp>
#include <rmm/device_buffer.hpp>
#include <rmm/mr/device/device_memory_resource.hpp>

#include <algorithm>
#include <functional>
#include <iterator>
#include <type_traits>

namespace cudf {

namespace ast {

namespace detail {

template <size_type block_size>
__launch_bounds__(block_size) __global__
  void compute_column_kernel(table_device_view const table,
                             const cudf::detail::fixed_width_scalar_device_view_base* literals,
                             mutable_column_device_view output_column,
                             const detail::device_data_reference* data_references,
                             const ast_operator* operators,
                             const cudf::size_type* operator_source_indices,
                             cudf::size_type num_operators,
                             cudf::size_type num_intermediates)
{
  extern __shared__ std::int64_t intermediate_storage[];
  auto thread_intermediate_storage = &intermediate_storage[threadIdx.x * num_intermediates];
  auto const start_idx             = cudf::size_type(threadIdx.x + blockIdx.x * blockDim.x);
  auto const stride                = cudf::size_type(blockDim.x * gridDim.x);
  auto const num_rows              = table.num_rows();
  auto const evaluator =
    cudf::ast::detail::row_evaluator(table, literals, thread_intermediate_storage, &output_column);

  for (cudf::size_type row_index = start_idx; row_index < num_rows; row_index += stride) {
    evaluate_row_expression(
      evaluator, data_references, operators, operator_source_indices, num_operators, row_index);
  }
}

std::unique_ptr<column> compute_column(table_view const table,
                                       expression const& expr,
                                       cudaStream_t stream,
                                       rmm::mr::device_memory_resource* mr)
{
  // Linearize the AST
  auto const expr_linearizer         = linearizer(expr, table);
  auto const data_references         = expr_linearizer.get_data_references();
  auto const literals                = expr_linearizer.get_literals();
  auto const operators               = expr_linearizer.get_operators();
  auto const num_operators           = cudf::size_type(operators.size());
  auto const operator_source_indices = expr_linearizer.get_operator_source_indices();
  auto const expr_data_type          = expr_linearizer.get_root_data_type();

  // Create ast_plan and device buffer
  auto plan = ast_plan();
  plan.add_to_plan(data_references);
  plan.add_to_plan(literals);
  plan.add_to_plan(operators);
  plan.add_to_plan(operator_source_indices);
  auto const host_data_buffer = plan.get_host_data_buffer();
  auto const buffer_offsets   = plan.get_offsets();
  auto const buffer_size      = host_data_buffer.second;
  auto device_data_buffer     = rmm::device_buffer(buffer_size, stream, mr);
  CUDA_TRY(cudaMemcpyAsync(device_data_buffer.data(),
                           host_data_buffer.first.get(),
                           buffer_size,
                           cudaMemcpyHostToDevice,
                           stream));
  // To reduce overhead, we don't call a stream sync here.
  // The stream is synced later when the table_device_view is created.

  // Create device pointers to components of plan
  auto const device_data_buffer_ptr = static_cast<const char*>(device_data_buffer.data());
  auto const device_data_references = reinterpret_cast<const detail::device_data_reference*>(
    device_data_buffer_ptr + buffer_offsets.at(0));
  auto const device_literals =
    reinterpret_cast<const cudf::detail::fixed_width_scalar_device_view_base*>(
      device_data_buffer_ptr + buffer_offsets.at(1));
  auto const device_operators =
    reinterpret_cast<const ast_operator*>(device_data_buffer_ptr + buffer_offsets.at(2));
  auto const device_operator_source_indices =
    reinterpret_cast<const cudf::size_type*>(device_data_buffer_ptr + buffer_offsets.at(3));

  // Create table device view
  auto table_device         = table_device_view::create(table, stream);
  auto const table_num_rows = table.num_rows();

  // Prepare output column
  auto output_column = cudf::make_fixed_width_column(
    expr_data_type, table_num_rows, mask_state::UNALLOCATED, stream, mr);
  auto mutable_output_device =
    cudf::mutable_column_device_view::create(output_column->mutable_view(), stream);

  // Configure kernel parameters
  auto const num_intermediates     = expr_linearizer.get_intermediate_count();
  auto const shmem_size_per_thread = static_cast<int>(sizeof(std::int64_t) * num_intermediates);
  int device_id;
  CUDA_TRY(cudaGetDevice(&device_id));
  int shmem_per_block_limit;
  CUDA_TRY(
    cudaDeviceGetAttribute(&shmem_per_block_limit, cudaDevAttrMaxSharedMemoryPerBlock, device_id));
  auto constexpr DEFAULT_BLOCK_SIZE = 512;
  auto const block_size =
    (shmem_size_per_thread > 0)
      ? std::min(DEFAULT_BLOCK_SIZE, shmem_per_block_limit / shmem_size_per_thread)
      : DEFAULT_BLOCK_SIZE;
  cudf::detail::grid_1d config(table_num_rows, block_size);
  auto const shmem_size_per_block = shmem_size_per_thread * config.num_threads_per_block;

  // Output linearizer info
  /*
  std::cout << "LINEARIZER INFO:" << std::endl;
  std::cout << "Number of data references: " << data_references.size() << std::endl;
  std::cout << "Data references: ";
  for (auto const& dr : data_references) {
    switch (dr.reference_type) {
      case detail::device_data_reference_type::COLUMN:
        if (dr.table_source == table_reference::LEFT) {
          std::cout << "C";
        } else {
          std::cout << "O";
        }
        break;
      case detail::device_data_reference_type::LITERAL: std::cout << "L"; break;
      case detail::device_data_reference_type::INTERMEDIATE: std::cout << "I";
    }
    std::cout << dr.data_index << "[typeid=" << static_cast<int>(dr.data_type.id()) << "], ";
  }
  std::cout << std::endl;
  std::cout << "Number of operators: " << num_operators << std::endl;
  std::cout << "Number of operator source indices: " << operator_source_indices.size() << std::endl;
  std::cout << "Number of literals: " << literals.size() << std::endl;
  std::cout << "Operator source indices: ";
  for (auto const& v : operator_source_indices) { std::cout << v << ", "; }
  std::cout << std::endl;
  std::cout << "Requesting " << config.num_blocks << " blocks, ";
  std::cout << config.num_threads_per_block << " threads/block, ";
  std::cout << shmem_size_per_block << " bytes of shared memory." << std::endl;
  */

  // Execute the kernel
  cudf::ast::detail::compute_column_kernel<DEFAULT_BLOCK_SIZE>
    <<<config.num_blocks, config.num_threads_per_block, shmem_size_per_block, stream>>>(
      *table_device,
      device_literals,
      *mutable_output_device,
      device_data_references,
      device_operators,
      device_operator_source_indices,
      num_operators,
      num_intermediates);
  CHECK_CUDA(stream);
  return output_column;
}

}  // namespace detail

std::unique_ptr<column> compute_column(table_view const table,
                                       expression const& expr,
                                       rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::compute_column(table, expr, 0, mr);
}

}  // namespace ast

}  // namespace cudf