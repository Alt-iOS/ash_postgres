# SPDX-FileCopyrightText: 2019 ash_postgres contributors <https://github.com/ash-project/ash_postgres/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshPostgres.Test.Tally do
  @moduledoc false
  use Ash.Resource,
    domain: AshPostgres.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("tallies")
    repo(AshPostgres.TestRepo)
    migration_ignore_attributes([:doubled])

    custom_statements do
      statement :doubled do
        up("ALTER TABLE tallies ADD COLUMN doubled bigint GENERATED ALWAYS AS (count * 2) STORED")
        down("ALTER TABLE tallies DROP COLUMN doubled")
      end
    end
  end

  actions do
    defaults([:read, :destroy, create: [:count]])

    update :add do
      argument(:by, :integer, allow_nil?: false)
      change(atomic_update(:count, expr(count + ^arg(:by))))
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:count, :integer, allow_nil?: false, public?: true)
    attribute(:doubled, :integer, generated?: true, writable?: false, public?: true)
  end
end
