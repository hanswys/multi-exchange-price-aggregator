module DashboardHelper
  # 67432.18 → "67,432.18". BigDecimal-safe.
  def format_price(value)
    big = BigDecimal(value.to_s)
    integer, fraction = big.round(2).to_s("F").split(".")
    "#{integer.reverse.scan(/\d{1,3}/).join(",").reverse}.#{fraction.ljust(2, '0')[0, 2]}"
  end

  # 0.4231 → "42.3%". Sources sum to 100% ± rounding.
  def format_weight(value)
    big = BigDecimal(value.to_s)
    "#{(big * 100).round(1).to_s("F")}%"
  end

  # Seconds → "1.21s" (under 10s) or "12.4s" (10s+). Always s suffix.
  def format_age(seconds)
    s = seconds.to_f
    s < 10 ? format("%.2fs", s) : format("%.1fs", s)
  end

  # UTC clock → "23:42:00 UTC".
  def format_clock_utc(time)
    time.utc.strftime("%H:%M:%S UTC")
  end
end
