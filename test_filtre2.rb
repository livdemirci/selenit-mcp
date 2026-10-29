# filtre2 ölçüt birim testi: tarayıcı gerekmez, ölçüt mantığı izole edilir.
#   ruby test_filtre2.rb
require_relative "tasks"

class FakeMcp
  def initialize(url, metin)
    @url = url
    @metin = metin
  end

  def call(_name, args)
    js = args["script"].to_s
    return @url if js.include?("return location.href")
    return @metin if js.include?("document.body.innerText")

    "#{@url},#{@metin.scan(/\d{6,12}/).join(',')}"
  end
end

ENV["SELENIT_FILTER_MIN"] = "500000"
ENV["SELENIT_FILTER_MAX"] = "1500000"
kontrol = TASKS["filtre2"][:check]

URL_OK = "https://x.test/bmw/216d/x-1995000tl-579213?min-fiyat=500000&max-fiyat=1500000"
METIN  = "BMW 216d 1.995.000 TL ilan no 579213"

TESTLER = [
  ["dogru cevap        ", URL_OK, METIN, "ilan | 579213 | 1.995.000 TL", true],
  ["uydurma ilan no    ", URL_OK, METIN, "ilan | 111111 | 1.995.000 TL", false],
  ["filtre uygulanmadi ", "https://x.test/bmw/216d/x-1995000tl-579213", METIN, "ilan | 579213 | 1.995.000 TL", false],
  ["fiyat yok          ", URL_OK, METIN, "ilan | 579213 | fiyat yok", false],
  ["sayfada no yok     ", URL_OK, "BMW 1.995.000 TL", "ilan | ilan no yok | 1.995.000 TL", true],
  ["uydurma fiyat      ", URL_OK, METIN, "ilan | 579213 | 900.000 TL", false],
  ["baska ilanin fiyati", URL_OK, METIN, "ilan | 579213 | 825.000 TL", false]
].freeze

hata = 0
TESTLER.each do |ad, url, metin, cevap, beklenen|
  gelen = begin
    kontrol.call(FakeMcp.new(url, metin), cevap)
  rescue StandardError
    "HATA"
  end
  ok = gelen == beklenen
  hata += 1 unless ok
  puts "#{ok ? 'PASS' : 'FAIL'} #{ad} beklenen=#{beklenen} gelen=#{gelen}"
end
puts
puts hata.zero? ? "OLCUT: #{TESTLER.size}/#{TESTLER.size} gecti" : "OLCUT: #{hata} hata"
exit(hata.zero? ? 0 : 1)
