# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ErrorExpr do
  @moduledoc false

  # Renders `error/2` as a call that also takes a row-dependent token. Postgres may run a call
  # whose arguments are all constants while it plans the query, even in a `CASE` branch no row
  # takes: it folds immutable functions, and evaluates stable ones to estimate a comparison's
  # selectivity. Such a call raises its error before any row is read. The token ties the call
  # to a row, so it only runs when a row reaches it.

  require Ecto.Query

  # How each volatility converts an input expression to jsonb, `null` included: `jsonb_set/4`
  # returns NULL when given a NULL value.
  @to_jsonb %{
    stable: {"COALESCE(to_jsonb(", "), 'null'::jsonb)"},
    immutable: {"ash_to_jsonb_immutable(", ")"}
  }

  # Renders the error with `ash-functions`' stable `ash_raise_error/3`, or with the
  # `AshPostgres.Extensions.ImmutableRaiseError` functions when `volatility` is `:immutable`.
  # Returns `:error`, leaving the error to `AshSql`'s call without a token, when the query has
  # no row to take a token from.
  @doc false
  def expr(
        query,
        %Ash.Query.Function.Error{arguments: [exception, input]} = value,
        bindings,
        acc,
        type,
        volatility
      ) do
    if !(Keyword.keyword?(input) or is_map(input)) do
      raise "Input expression to `error` must be a map or keyword list"
    end

    acc = %{acc | has_error?: true}

    {error_payload, acc} =
      if Ash.Expr.expr?(input) do
        expression_error_payload(exception, input, query, bindings, acc, volatility)
      else
        {Jason.encode!(%{exception: inspect(exception), input: Map.new(input)}), acc}
      end

    dynamic_type =
      if type do
        # This is a type hint, if we're raising an error, we tell it what the value
        # type *would* be in this expression so that we can return a "NULL" of that type
        # its weird, but there isn't any other way that I can tell :)
        AshSql.Expr.validate_type!(query, type, value)

        type =
          AshSql.Expr.parameterized_type(
            bindings.sql_behaviour,
            type,
            [],
            :expr
          )

        Ecto.Query.dynamic(type(fragment("NULL"), ^type))
      end

    case {volatility, dynamic_type, row_token(query, bindings)} do
      {_, _, nil} ->
        :error

      # Two arguments would call `ash_raise_error/2`, whose second is a type signal, so the token
      # always goes third. Without a type, the signal is a boolean, as `ash_raise_error/1` returns.
      {:stable, nil, row_token} ->
        {:ok,
         Ecto.Query.dynamic(
           fragment(
             "ash_raise_error(?::jsonb, ?, ?)",
             ^error_payload,
             type(fragment("NULL"), :boolean),
             ^row_token
           )
         ), acc}

      {:stable, dynamic_type, row_token} ->
        {:ok,
         Ecto.Query.dynamic(
           fragment(
             "ash_raise_error(?::jsonb, ?, ?)",
             ^error_payload,
             ^dynamic_type,
             ^row_token
           )
         ), acc}

      {:immutable, nil, row_token} ->
        {:ok,
         Ecto.Query.dynamic(
           fragment("ash_raise_error_immutable(?::jsonb, ?)", ^error_payload, ^row_token)
         ), acc}

      {:immutable, dynamic_type, row_token} ->
        {:ok,
         Ecto.Query.dynamic(
           fragment(
             "ash_raise_error_immutable(?::jsonb, ?, ?)",
             ^error_payload,
             ^dynamic_type,
             ^row_token
           )
         ), acc}
    end
  end

  # Encodes an error payload as jsonb.
  #
  # Strategy:
  # * Split the 'input' into Ash expressions and literal values
  # * Build the base json map with the exception name and literal input values
  # * For each expression value, use nested calls to `jsonb_set` (IMMUTABLE) to add the value to
  #   'input', converting each expression to jsonb (with `ash_to_jsonb_immutable` for immutable
  #   errors, which pins session GUCs for deterministic encoding)
  defp expression_error_payload(exception, input, query, bindings, acc, volatility) do
    {expr_inputs, literal_inputs} =
      Enum.split_with(input, fn {_key, value} -> Ash.Expr.expr?(value) end)

    base_json = %{exception: inspect(exception), input: Map.new(literal_inputs)}
    {to_jsonb_open, to_jsonb_close} = Map.fetch!(@to_jsonb, volatility)

    Enum.reduce(expr_inputs, {base_json, acc}, fn
      {key, expr_value}, {current_payload, acc} ->
        path_expr = %Ash.Query.Function.Type{
          arguments: [["input", to_string(key)], {:array, :string}, []]
        }

        new_value_jsonb =
          %Ash.Query.Function.Fragment{
            arguments: [raw: to_jsonb_open, expr: expr_value, raw: to_jsonb_close]
          }

        {%Ecto.Query.DynamicExpr{} = new_payload, acc} =
          AshSql.Expr.dynamic_expr(
            query,
            %Ash.Query.Function.Fragment{
              arguments: [
                raw: "jsonb_set(",
                expr: current_payload,
                raw: "::jsonb, ",
                expr: path_expr,
                raw: ", ",
                expr: new_value_jsonb,
                raw: "::jsonb, true)"
              ]
            },
            bindings,
            false,
            nil,
            acc
          )

        {new_payload, acc}
    end)
  end

  # Returns a row-dependent token, or `nil` when the query has no row to take it from. Without a
  # row, every condition is a constant, and Postgres drops a branch whose condition is false
  # before it simplifies the branch, so the call needs no token there.
  @doc false
  def row_token(_query, %{no_row?: true}), do: nil

  def row_token(query, bindings) do
    resource = query.__ash_bindings__.resource
    ref_binding = bindings.root_binding

    pk_attr_names = Ash.Resource.Info.primary_key(resource)

    attr_names =
      case pk_attr_names do
        [] ->
          case Ash.Resource.Info.attributes(resource) do
            [%{name: name} | _] -> [name]
            _ -> []
          end

        pk ->
          pk
      end

    if ref_binding && attr_names != [] do
      value_exprs =
        Enum.map(attr_names, fn attr_name ->
          if bindings[:parent?] &&
               ref_binding not in List.wrap(bindings[:lateral_join_bindings]) do
            Ecto.Query.dynamic(field(parent_as(^ref_binding), ^attr_name))
          else
            Ecto.Query.dynamic(field(as(^ref_binding), ^attr_name))
          end
        end)

      row_parts =
        value_exprs
        |> Enum.map(&{:casted_expr, &1})
        |> Enum.intersperse({:raw, ", "})

      {%Ecto.Query.DynamicExpr{} = token, _acc} =
        AshSql.Expr.dynamic_expr(
          query,
          %Ash.Query.Function.Fragment{
            embedded?: false,
            arguments: [raw: "ROW("] ++ row_parts ++ [raw: ")"]
          },
          AshSql.Expr.set_location(bindings, :sub_expr),
          false
        )

      token
    end
  end
end
