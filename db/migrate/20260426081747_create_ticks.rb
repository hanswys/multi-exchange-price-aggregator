class CreateTicks < ActiveRecord::Migration[8.1]
  def up
    execute "CREATE EXTENSION IF NOT EXISTS timescaledb"

    create_table :ticks, id: false do |t|
      t.string     :exchange,         null: false
      t.string     :pair,             null: false
      t.decimal    :price,            precision: 20, scale: 8, null: false
      t.decimal    :quote_volume_24h, precision: 28, scale: 8, null: false
      t.timestamptz :source_ts,       null: false
      t.timestamptz :ingested_ts,     null: false
    end

    execute "SELECT create_hypertable('ticks', 'ingested_ts', if_not_exists => TRUE)"

    add_index :ticks,
              [ :exchange, :pair, :ingested_ts ],
              order: { ingested_ts: :desc },
              name:  "idx_ticks_lookup"
  end

  def down
    drop_table :ticks
  end
end
