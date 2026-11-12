# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.GeneratedAttributeUpdateTest do
  use AshPostgres.RepoCase, async: false

  alias AshPostgres.Test.Tally

  test "an update of one record returns the attributes the database generates as it computed them" do
    tally =
      Tally
      |> Ash.Changeset.for_create(:create, %{count: 1})
      |> Ash.create!()

    assert tally.doubled == 2

    updated =
      tally
      |> Ash.Changeset.for_update(:add, %{by: 2})
      |> Ash.update!()

    assert updated.count == 3
    assert updated.doubled == 6
  end
end
