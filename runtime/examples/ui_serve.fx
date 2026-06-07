# Flux Frontend — 3+5a BOSQICH misoli: page routing + ui.serve + interaktivlik.
#
# `page "/yo'l" -> view` URL'ni view'ga bog'laydi. `ui.serve port` bitta portda
# HTML sahifa (page) + REST API (http.on) + /_fx/event (server-driven) beradi.
#
# AVTOMATIK AJRATISH: `home` da `q <- ""` + `bind:q` bor -> qidiruv qismi CLIENT
# ISLAND (interaktiv, jonli filtr server-driven), qolgani SOF SSR (0 JS, statik).
# Dasturchi hech narsa belgilamaydi — analyzer o'zi aniqlaydi.
#
# DIQQAT: bu fayl portni ochib BLOKLAYDI (server) — smoke-test uchun emas.
# Ishga tushirish: cargo run -- run examples/ui_serve.fx, keyin brauzerda och,
# qidiruv maydoniga yoz -> ro'yxat jonli filtrlanadi (server-driven, RAM'siz).

theme
  primary "#e84d8a"
  radius  :lg
  muted   "#888"

view home
  q <- ""
  h1 "Gulzor"
  p "Eng yaxshi gullar shu yerda" {kind::muted}
  div {kind::panel}
    input {bind:q placeholder:"Gul qidir..."}
    each g in ["Atirgul" "Lola" "Chinnigul" "Nilufar"]
      if str.has (str.low g) (str.low q)
        h2 g

# 1-param view — req (params/query) oladi.
view product req
  h1 "Mahsulot #${req.params.id}"
  p "Tafsilot sahifasi"

# REST API — UI bilan BIR portda (/api prefiksli).
http.on :get "/api/health" \req -> rep 200 {ok:true}

# page marshrutlari (URL = sahifa).
page "/" -> home
page "/product/:id" \req -> product req

# Bitta port: SSR sahifa + REST + (kelajakda) WS.
ui.serve 3777
