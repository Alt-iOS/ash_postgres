# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.ErrorExprTest do
  use AshPostgres.RepoCase, async: false
  alias AshPostgres.Test.Post

  require Ash.Query
  import Ash.Expr

  test "exceptions in filters are treated as regular Ash exceptions" do
    Post
    |> Ash.Changeset.for_create(:create, %{title: "title"})
    |> Ash.create!()

    assert_raise Ash.Error.Invalid, ~r/this is bad!/, fn ->
      Post
      |> Ash.Query.filter(
        error(Ash.Error.Query.InvalidFilterValue, message: "this is bad!", value: 10)
      )
      |> Ash.read!()
    end
  end

  test "an error in a branch no row takes doesn't raise while Postgres plans the query" do
    post =
      Post
      |> Ash.Changeset.for_create(:create, %{title: "title", score: 1})
      |> Ash.create!()

    AshPostgres.Test.Comment
    |> Ash.Changeset.for_create(:create, %{title: "x"})
    |> Ash.Changeset.manage_relationship(:post, post, type: :append_and_remove)
    |> Ash.create!()

    # Under `or`, the `exists` stays a subquery and the parent's score is a parameter there, so
    # the comparison's right side is constant to the comments it scans. Postgres estimates it by
    # evaluating the stable error call ahead of time, unless the call has a row-dependent argument.
    assert [%{id: id}] =
             Post
             |> Ash.Query.filter(
               score == 2 or
                 exists(
                   comments,
                   title ==
                     if(parent(score) > 100,
                       do: error(Ash.Error.Query.InvalidFilterValue, message: "never", value: 10),
                       else: "x"
                     )
                 )
             )
             |> Ash.read!()

    assert id == post.id
  end

  test "the data layer's calculate, with no row to refer to, returns the expression's error" do
    {:ok, expression} =
      Ash.Filter.hydrate_refs(
        expr(error(Ash.Error.Query.InvalidFilterValue, message: "always raises", value: 10)),
        %{resource: Post}
      )

    assert {:error, %Ash.Error.Query.InvalidFilterValue{message: "always raises"}} =
             AshPostgres.DataLayer.calculate(Post, [expression], %{})
  end

  test "exceptions in calculations are treated as regular Ash exceptions" do
    Post
    |> Ash.Changeset.for_create(:create, %{title: "title"})
    |> Ash.create!()

    assert_raise Ash.Error.Invalid, ~r/this is bad!/, fn ->
      Post
      |> Ash.Query.calculate(
        :test,
        :string,
        expr(error(Ash.Error.Query.InvalidFilterValue, message: "this is bad!", value: 10))
      )
      |> Ash.read!()
      |> Enum.map(& &1.calculations)
    end
  end

  test "exceptions in calculations are treated as regular Ash exceptions in transactions" do
    Post
    |> Ash.Changeset.for_create(:create, %{title: "title"})
    |> Ash.create!()

    assert_raise Ash.Error.Invalid, ~r/this is bad!/, fn ->
      AshPostgres.TestRepo.transaction!(fn ->
        Post
        |> Ash.Query.calculate(
          :test,
          :string,
          expr(error(Ash.Error.Query.InvalidFilterValue, message: "this is bad!", value: 10))
        )
        |> Ash.read!()
        |> Enum.map(& &1.calculations)
      end)
    end
  end

  # The savepoint that turns a raised expression into a regular Ash error (rather than a raw
  # Postgrex error that aborts the transaction) must cover the upsert condition too, not just
  # the SET clause.
  test "exceptions raised by an upsert condition are treated as regular Ash exceptions" do
    id = Ash.UUID.generate()

    Post
    |> Ash.Changeset.for_create(:create, %{id: id, title: "title"})
    |> Ash.create!()

    result =
      Ash.bulk_create(
        [%{id: id, title: "title2"}],
        Post,
        :create,
        upsert?: true,
        upsert_fields: [:title],
        upsert_condition:
          expr(error(Ash.Error.Query.InvalidFilterValue, message: "this is bad!", value: 10)),
        return_errors?: true
      )

    assert %Ash.BulkResult{status: :error, errors: [error]} = result
    assert Exception.message(error) =~ "this is bad!"

    # The connection is still usable afterwards rather than left in an aborted-transaction state.
    assert Ash.count!(Post) == 1
  end
end
