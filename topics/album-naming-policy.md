# Album Naming & Organization Policy

## State

Decided 2026-09-01. Applied 2026-09-01 — all existing albums renamed under
this scheme (e.g. `Tour: 2017` variants, `Family Reunion`) and the album
list view set to display "Group by year". **Done.**

## Design

Immich's album list view offers three grouping modes: "No Grouping"
(alphabetical), "Group by year", and "Group by owner". Using **"Group by
year"** provides a year dimension for free, at the album-list level —
freeing the album name itself from having to encode the year.

This separates three previously-overloaded fields:

- **Album name** — descriptive only, no year (e.g. `Tour: Canada`,
  `Reunion: Ensign Ranch`, `Reunion: Lincoln City`, `Reunion: Dads Lane`).
  Immich's year grouping places each into its correct year automatically.
- **Album description** — descriptive detail about what the album
  contains, no longer needed to disambiguate same-named albums by year
  (the old workaround — see `topics/timezone-correction.md`'s note on
  `Tour: 2017` — since the year no longer needs to live anywhere in the
  name at all).
- **Photo description** — reserved for describing the individual photo,
  not the album.

Net effect: what used to be one large `Family Reunion` album spanning many
years (or several same-named `Tour: 2017` albums distinguished only by
description) becomes multiple distinctly-named albums, each landing in its
own year group automatically — album identity now carries one dimension
(what/where), year grouping carries the other (when), rather than cramming
both into the name or leaning on description to disambiguate.
