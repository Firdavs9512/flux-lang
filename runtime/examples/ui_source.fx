# Flux Frontend — PR-7a misoli: `source` reaktiv data (server-only, SSR-first).
#
# `items <- source db.q "..."` — backend db.q SERVER'da bajariladi, view
# `.data`/`.loading`/`.err`/`.reload()` oladi. GLUE-KOD YO'Q (fetch/useEffect/parse
# yo'q). Sahifa data bilan keladi (SSR, 0 qo'shimcha round-trip).
#
# AVTOMATIK AJRATISH: `q <- ""` + bind:q + source.data.filter -> div CLIENT ISLAND
# (jonli filtr server-driven), h1 SOF SSR (0 JS). Dasturchi hech narsa belgilamaydi.
#
# DIQQAT: portni ochib BLOKLAYDI (server) — smoke-test emas.
# Ishga tushirish:
#   DATABASE_URL="sqlite::memory:" cargo run -- run examples/ui_source.fx
# keyin brauzerda och, qidiruv maydoniga yoz -> ro'yxat jonli filtrlanadi.
#
# PR-7a doira: statik source (db.q/db.one/http.get) SSR'da bajariladi.
# `source live` (WS real-time) + `ui.push` (broadcast) = PR-7b.

use db

tbl gul
  id    serial pk
  name  str
  narx  int

db.ins "gul" {name:"Atirgul"  narx:25000}
db.ins "gul" {name:"Lola"     narx:18000}
db.ins "gul" {name:"Chinnigul" narx:30000}
db.ins "gul" {name:"Nilufar"  narx:45000}

theme
  primary "#e84d8a"
  radius  :lg

view shop
  # source: db.q server'da bajariladi, items.data = qatorlar (SSR'da to'la).
  items <- source db.q "select * from gul order by narx"
  q     <- ""
  # derived: reaktiv filtr (q o'zgarsa qayta hisoblanadi).
  shown = items.data.filter \g -> str.has (str.low g.name) (str.low q)

  h1 "Gulzor — ${items.data.len} ta gul"
  div {kind::panel}
    input {bind:q placeholder:"Gul qidir..."}
    if items.err
      p "Xato: ${items.err}" {kind::danger}
    else
      each g in shown
        div {kind::row}
          h2 g.name
          span "${g.narx/100} so'm" {kind::muted}

page "/" -> shop

# Bitta port: SSR sahifa (source data bilan) + /_fx/event (jonli filtr).
ui.serve 3779
