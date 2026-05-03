namespace :aggregator do
  desc "Fetch a single Tick from one Source. Manual smoke test. " \
       "Usage: rake aggregator:fetch[binance,BTC-USD]"
  task :fetch, [ :exchange, :pair ] => :environment do |_t, args|
    exchange = args[:exchange]
    pair = args[:pair]

    abort "usage: rake aggregator:fetch[exchange,pair]" if exchange.blank? || pair.blank?

    adapter_class =
      case exchange
      when "binance" then Aggregator::Sources::Binance
      else
        abort "unknown exchange: #{exchange.inspect}. supported: binance"
      end

    tick = adapter_class.new.fetch(pair)

    puts "exchange:         #{tick.exchange}"
    puts "pair:             #{tick.pair}"
    puts "price:            #{tick.price.to_s('F')}"
    puts "quote_volume_24h: #{tick.quote_volume_24h.to_s('F')}"
    puts "source_ts:        #{tick.source_ts.iso8601(3)}"
    puts "ingested_ts:      #{tick.ingested_ts.iso8601(3)}"
  rescue Aggregator::Sources::Error, ArgumentError => e
    abort "#{e.class}: #{e.message}"
  end
end
