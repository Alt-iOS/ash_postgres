# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Extensions.ImmutableRaiseError do
  @moduledoc """
  An extension that installs an immutable version of ash_raise_error.

  This can be used to improve compatibility with Postgres sharding extensions like Citus,
  which requires functions used in CASE or COALESCE expressions to be immutable.

  The new `ash_raise_error_immutable` functions add an additional row-dependent argument to ensure
  the planner doesn't constant-fold error expressions.

  To install, add this module to your repo's `installed_extensions` list:

  ```elixir
  def installed_extensions do
    ["ash-functions", AshPostgres.Extensions.ImmutableRaiseError]
  end
  ```

  And run `mix ash_postgres.generate_migrations` to generate the migrations.

  Once installed, you can control whether the immutable function is used by adding this to your
  repo:

  ```elixir
  def immutable_expr_error?, do: true
  ```
  """

  use AshPostgres.CustomExtension, name: "immutable_raise_error", latest_version: 2

  require Ecto.Query

  @impl true
  def install(0) do
    """
    #{ash_raise_error_immutable()}

    #{ash_to_jsonb_immutable()}
    """
  end

  def install(1) do
    ash_to_jsonb_immutable()
  end

  @impl true
  def uninstall(2) do
    "execute(\"DROP FUNCTION IF EXISTS ash_to_jsonb_immutable(anyelement)\")"
  end

  def uninstall(_version) do
    "execute(\"DROP FUNCTION IF EXISTS ash_to_jsonb_immutable(anyelement), ash_raise_error_immutable(jsonb, anycompatible), ash_raise_error_immutable(jsonb, anyelement, anycompatible)\")"
  end

  defp ash_raise_error_immutable do
    """
    execute(\"\"\"
    CREATE OR REPLACE FUNCTION ash_raise_error_immutable(json_data jsonb, token anycompatible)
    RETURNS boolean AS $$
    BEGIN
        -- Raise an error with the provided JSON data.
        -- The JSON object is converted to text for inclusion in the error message.
        -- 'token' is intentionally ignored; its presence makes the call non-constant at the call site.
        RAISE EXCEPTION 'ash_error: %', json_data::text;
        RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    IMMUTABLE
    SET search_path = '';
    \"\"\")

    execute(\"\"\"
    CREATE OR REPLACE FUNCTION ash_raise_error_immutable(json_data jsonb, type_signal anyelement, token anycompatible)
    RETURNS anyelement AS $$
    BEGIN
        -- Raise an error with the provided JSON data.
        -- The JSON object is converted to text for inclusion in the error message.
        -- 'token' is intentionally ignored; its presence makes the call non-constant at the call site.
        RAISE EXCEPTION 'ash_error: %', json_data::text;
        RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    IMMUTABLE
    SET search_path = '';
    \"\"\")
    """
  end

  # Wraps to_jsonb and pins session GUCs that affect JSON. This makes the function’s result
  # deterministic, so it is safe to mark IMMUTABLE.
  defp ash_to_jsonb_immutable do
    """
    execute(\"\"\"
    CREATE OR REPLACE FUNCTION ash_to_jsonb_immutable(value anyelement)
     RETURNS jsonb
     LANGUAGE plpgsql
     IMMUTABLE
     SET search_path TO 'pg_catalog'
     SET \"TimeZone\" TO 'UTC'
     SET \"DateStyle\" TO 'ISO, YMD'
     SET \"IntervalStyle\" TO 'iso_8601'
     SET extra_float_digits TO '0'
     SET bytea_output TO 'hex'
    AS $function$
    BEGIN
      RETURN COALESCE(to_jsonb(value), 'null'::jsonb);
    END;
    $function$
    \"\"\")
    """
  end

  @doc false
  def immutable_required_expr(
        query,
        %{name: :required!, arguments: [value_expr, attribute]} = required,
        bindings,
        embedded?,
        acc,
        type
      ) do
    pred_embedded? = Map.get(required, :embedded?, false)

    {value_dyn, acc} =
      AshSql.Expr.dynamic_expr(
        query,
        value_expr,
        bindings,
        pred_embedded? || embedded?,
        type,
        acc
      )

    resource =
      Map.get(attribute, :resource) ||
        raise("attribute must have :resource for ash_required!")

    field =
      Map.get(attribute, :name) ||
        Map.get(attribute, "name") ||
        raise("attribute must have :name for ash_required!")

    payload =
      %{
        exception: inspect(Ash.Error.Changes.Required),
        input: %{field: field, type: :attribute, resource: resource}
      }
      |> Jason.encode!()

    case AshPostgres.ErrorExpr.row_token(query, bindings) do
      nil ->
        :error

      row_token ->
        {:ok,
         Ecto.Query.dynamic(
           fragment(
             "CASE WHEN ? IS NULL THEN ash_raise_error_immutable(?::jsonb, ?, ?) ELSE ? END",
             ^value_dyn,
             ^payload,
             ^value_dyn,
             ^row_token,
             ^value_dyn
           )
         ), acc}
    end
  end
end
