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
#pragma once

#include <cudf/ast/linearizer.cuh>
#include <cudf/ast/operators.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/scalar/scalar.hpp>
#include <cudf/scalar/scalar_device_view.cuh>
#include <cudf/table/table.hpp>
#include <cudf/table/table_device_view.cuh>
#include <cudf/table/table_view.hpp>
#include <cudf/types.hpp>

namespace cudf {

namespace ast {

namespace detail {

/**
 * @brief An expression evaluator owned by a single thread operating on rows of a table.
 *
 * This class is designed for n-ary transform evaluation. Currently this class assumes that there's
 * only one relevant "row index" in its methods, which corresponds to a row in a single input table
 * and the same row index in an output column.
 *
 */
struct row_evaluator {
 public:
  /**
   * @brief Construct a row evaluator.
   *
   * @param table The table device view used for evaluation.
   * @param literals Array of literal values used for evaluation.
   * @param thread_intermediate_storage Pointer to this thread's portion of shared memory for
   * storing intermediates.
   * @param output_column The output column where results are stored.
   */
  __device__ row_evaluator(const table_device_view table,
                           const cudf::detail::fixed_width_scalar_device_view_base* literals,
                           std::int64_t* thread_intermediate_storage,
                           mutable_column_device_view* output_column)
    : table(table),
      literals(literals),
      thread_intermediate_storage(thread_intermediate_storage),
      output_column(output_column)
  {
  }

  /**
   * @brief Resolves an input data reference into a value.
   *
   * Only input columns (COLUMN), literal values (LITERAL), and intermediates (INTERMEDIATE) are
   * supported as input data references. Intermediates must be of fixed width less than or equal to
   * sizeof(std::int64_t). This requirement on intermediates is enforced by the linearizer.
   *
   * @tparam Element Type of element to return.
   * @param device_data_reference Data reference to resolve.
   * @param row_index Row index of data column.
   * @return Element
   */
  template <typename Element>
  __device__ Element resolve_input(const detail::device_data_reference device_data_reference,
                                   cudf::size_type row_index) const
  {
    auto const data_index = device_data_reference.data_index;
    auto const ref_type   = device_data_reference.reference_type;
    if (ref_type == detail::device_data_reference_type::COLUMN) {
      auto column = this->table.column(data_index);
      return column.element<Element>(row_index);
    } else if (ref_type == detail::device_data_reference_type::LITERAL) {
      return this->literals[data_index].value<Element>();
    } else {  // Assumes type == detail::device_data_reference_type::INTERMEDIATE
      // Using memcpy instead of reinterpret_cast<Element*> for safe type aliasing
      // Using a temporary variable ensures that the compiler knows the result is aligned
      std::int64_t intermediate = this->thread_intermediate_storage[data_index];
      Element tmp;
      memcpy(&tmp, &intermediate, sizeof(Element));
      return tmp;
    }
  }

  /**
   * @brief Resolves an output data reference and assigns result value.
   *
   * Only output columns (COLUMN) and intermediates (INTERMEDIATE) are supported as output reference
   * types. Intermediates must be of fixed width less than or equal to sizeof(std::int64_t). This
   * requirement on intermediates is enforced by the linearizer.
   *
   * @tparam Element Type of result element.
   * @param device_data_reference Data reference to resolve.
   * @param row_index Row index of data column.
   * @param result Value to assign to output.
   */
  template <typename Element>
  __device__ void resolve_output(const detail::device_data_reference device_data_reference,
                                 cudf::size_type row_index,
                                 Element result) const
  {
    auto const ref_type = device_data_reference.reference_type;
    if (ref_type == detail::device_data_reference_type::COLUMN) {
      this->output_column->element<Element>(row_index) = result;
    } else {  // Assumes type == detail::device_data_reference_type::INTERMEDIATE
      // Using memcpy instead of reinterpret_cast<Element*> for safe type aliasing
      // Using a temporary variable ensures that the compiler knows the result is aligned
      std::int64_t tmp;
      memcpy(&tmp, &result, sizeof(Element));
      this->thread_intermediate_storage[device_data_reference.data_index] = tmp;
    }
  }

  /**
   * @brief Callable to perform a unary operation.
   *
   * @tparam OperatorFunctor Functor that performs desired operation when `operator()` is called.
   * @tparam Input Type of input value.
   * @param row_index Row index of data column(s).
   * @param input Input data reference.
   * @param output Output data reference.
   */
  template <typename OperatorFunctor,
            typename Input,
            std::enable_if_t<cudf::ast::is_valid_unary_op<OperatorFunctor, Input>>* = nullptr>
  __device__ void operator()(cudf::size_type row_index,
                             const detail::device_data_reference input,
                             const detail::device_data_reference output) const
  {
    using Out              = simt::std::invoke_result_t<OperatorFunctor, Input>;
    auto const typed_input = this->resolve_input<Input>(input, row_index);
    this->resolve_output<Out>(output, row_index, OperatorFunctor{}(typed_input));
  }

  template <typename OperatorFunctor,
            typename Input,
            std::enable_if_t<!cudf::ast::is_valid_unary_op<OperatorFunctor, Input>>* = nullptr>
  __device__ void operator()(cudf::size_type row_index,
                             const detail::device_data_reference input,
                             const detail::device_data_reference output) const
  {
    release_assert(false && "Invalid unary dispatch operator for the provided input.");
  }

  /**
   * @brief Callable to perform a binary operation.
   *
   * @tparam OperatorFunctor Functor that performs desired operation when `operator()` is called.
   * @tparam LHS Type of left input value.
   * @tparam RHS Type of right input value.
   * @param row_index Row index of data column(s).
   * @param lhs Left input data reference.
   * @param rhs Right input data reference.
   * @param output Output data reference.
   */
  template <typename OperatorFunctor,
            typename LHS,
            typename RHS,
            std::enable_if_t<cudf::ast::is_valid_binary_op<OperatorFunctor, LHS, RHS>>* = nullptr>
  __device__ void operator()(cudf::size_type row_index,
                             const detail::device_data_reference lhs,
                             const detail::device_data_reference rhs,
                             const detail::device_data_reference output) const
  {
    using Out            = simt::std::invoke_result_t<OperatorFunctor, LHS, RHS>;
    auto const typed_lhs = this->resolve_input<LHS>(lhs, row_index);
    auto const typed_rhs = this->resolve_input<RHS>(rhs, row_index);
    this->resolve_output<Out>(output, row_index, OperatorFunctor{}(typed_lhs, typed_rhs));
  }

  template <typename OperatorFunctor,
            typename LHS,
            typename RHS,
            std::enable_if_t<!cudf::ast::is_valid_binary_op<OperatorFunctor, LHS, RHS>>* = nullptr>
  __device__ void operator()(cudf::size_type row_index,
                             const detail::device_data_reference lhs,
                             const detail::device_data_reference rhs,
                             const detail::device_data_reference output) const
  {
    release_assert(false && "Invalid binary dispatch operator for the provided input.");
  }

 private:
  const table_device_view table;
  const cudf::detail::fixed_width_scalar_device_view_base* literals;
  std::int64_t* thread_intermediate_storage;
  mutable_column_device_view* output_column;
};

/**
 * @brief Evaluate an expression applied to a row.
 *
 * This function performs an n-ary transform for one row on one thread.
 *
 * @param evaluator The row evaluator used for evaluation.
 * @param data_references Array of data references.
 * @param operators Array of operators to perform.
 * @param operator_source_indices Array of source indices for the operators.
 * @param num_operators Number of operators.
 * @param row_index Row index of data column(s).
 */
__device__ void evaluate_row_expression(const detail::row_evaluator evaluator,
                                        const detail::device_data_reference* data_references,
                                        const ast_operator* operators,
                                        const cudf::size_type* operator_source_indices,
                                        cudf::size_type num_operators,
                                        cudf::size_type row_index)
{
  auto operator_source_index = cudf::size_type(0);
  for (cudf::size_type operator_index(0); operator_index < num_operators; operator_index++) {
    // Execute operator
    auto const op    = operators[operator_index];
    auto const arity = cudf::ast::ast_operator_arity(op);
    if (arity == 1) {
      // Unary operator
      auto const input  = data_references[operator_source_indices[operator_source_index]];
      auto const output = data_references[operator_source_indices[operator_source_index + 1]];

      unary_operator_dispatcher(op, input.data_type, evaluator, row_index, input, output);
    } else if (arity == 2) {
      // Binary operator
      auto const lhs    = data_references[operator_source_indices[operator_source_index]];
      auto const rhs    = data_references[operator_source_indices[operator_source_index + 1]];
      auto const output = data_references[operator_source_indices[operator_source_index + 2]];
      binary_operator_dispatcher(
        op, lhs.data_type, rhs.data_type, evaluator, row_index, lhs, rhs, output);
    } else {
      release_assert(false && "Invalid operator arity.");
    }
    operator_source_index += (arity + 1);
  }
}

/**
 * @brief Kernel for evaluating an expression on a table to produce a new column.
 *
 * This evaluates an expression over a table to produce a new column. Also called an n-ary
 * transform.
 *
 * @tparam block_size
 * @param table The table device view used for evaluation.
 * @param literals Array of literal values used for evaluation.
 * @param output_column The output column where results are stored.
 * @param data_references Array of data references.
 * @param operators Array of operators to perform.
 * @param operator_source_indices Array of source indices for the operators.
 * @param num_operators Number of operators.
 * @param num_intermediates Number of intermediates, used to allocate a portion of shared memory to
 * each thread.
 */
template <size_type block_size>
__launch_bounds__(block_size) __global__
  void compute_column_kernel(const table_device_view table,
                             const cudf::detail::fixed_width_scalar_device_view_base* literals,
                             mutable_column_device_view output_column,
                             const detail::device_data_reference* data_references,
                             const ast_operator* operators,
                             const cudf::size_type* operator_source_indices,
                             cudf::size_type num_operators,
                             cudf::size_type num_intermediates);

/**
 * @brief Compute a new column by evaluating an expression tree on a table.
 *
 * This evaluates an expression over a table to produce a new column. Also called an n-ary
 * transform.
 *
 * @param table The table used for expression evaluation.
 * @param expr The root of the expression tree.
 * @param stream Stream on which to perform the computation.
 * @param mr Device memory resource.
 * @return std::unique_ptr<column> Output column.
 */
std::unique_ptr<column> compute_column(
  table_view const table,
  expression const& expr,
  cudaStream_t stream                 = 0,  // TODO use detail API
  rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource());

}  // namespace detail

/**
 * @brief Compute a new column by evaluating an expression tree on a table.
 *
 * This evaluates an expression over a table to produce a new column. Also called an n-ary
 * transform.
 *
 * @param table The table used for expression evaluation.
 * @param expr The root of the expression tree.
 * @param mr Device memory resource.
 * @return std::unique_ptr<column> Output column.
 */
std::unique_ptr<column> compute_column(
  table_view const table,
  expression const& expr,
  rmm::mr::device_memory_resource* mr = rmm::mr::get_default_resource());

}  // namespace ast

}  // namespace cudf
