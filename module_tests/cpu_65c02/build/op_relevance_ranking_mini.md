# A3 - both-fail opcode real-world relevance ranking

Population: the 105 opcodes with MOS both-fail tests in the T1 join
(build/new6502_three_way_join.md section 5: 4827 both-fail tests).

## Method

- STATIC byte histogram over whole images. A byte appearing anywhere
  is an UPPER BOUND on executions as an opcode (it may be data or an
  operand). ZERO hits across all images is a strong never-executed
  signal; nonzero hits say plausible, not executed.
- Confidence: image-wide (code-region boundaries not identified in
  v1). Refinement path: locate Total Replay boot/OS tracks and
  re-histogram just those (future pass).
- No 6502/65C02 opcode table is embedded: legality is not a ranking
  input. Judge legality against the standard 65C02 table before
  acting on any row; the campaign `class` column (from the join) is
  the existing classification.
- Ranking: (real-code hits desc, C5+C6 desc, op asc).
- Deterministic; re-run reproduces this file byte-for-byte.

## Images (read-only proof: sha256 before == after for all)

| image | path | bytes | sha256 |
|-------|------|-------|--------|
| MiniReplay.dsk | E:/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/disks/Mini Replay v1.1.dsk | 143360 | aceff64159d3f90af5d8071001e34ae39a838c2812384aafefc7b02fea7e3fd1 |

## Ranked table (all 105 both-fail ops)

| op | class | both-fail | C5 | C6 | hits(MiniReplay.dsk) | total | label |
|----|-------|-----------|----|----|------------|-----------|-------------|
| ff | OTHER | 50 | 0 | 29 | 1245 | 1245 | fix now (top quartile of real-code hits) |
| 02 | broken-ref | 50 | 50 | 0 | 1195 | 1195 | fix now (top quartile of real-code hits) |
| 03 | broken-ref | 50 | 0 | 0 | 1015 | 1015 | fix now (top quartile of real-code hits) |
| 04 | OTHER | 50 | 0 | 0 | 919 | 919 | fix now (top quartile of real-code hits) |
| fb | broken-ref | 50 | 0 | 34 | 789 | 789 | fix now (top quartile of real-code hits) |
| 07 | broken-ref | 50 | 0 | 0 | 776 | 776 | fix now (top quartile of real-code hits) |
| 22 | broken-ref | 50 | 50 | 0 | 755 | 755 | fix now (top quartile of real-code hits) |
| fa | OTHER | 50 | 0 | 0 | 707 | 707 | fix now (top quartile of real-code hits) |
| f9 | OTHER | 1 | 0 | 1 | 695 | 695 | fix now (top quartile of real-code hits) |
| fc | OTHER | 50 | 0 | 0 | 689 | 689 | fix now (top quartile of real-code hits) |
| fd | OTHER | 4 | 0 | 4 | 687 | 687 | fix now (top quartile of real-code hits) |
| f7 | broken-ref | 50 | 0 | 36 | 663 | 663 | fix now (top quartile of real-code hits) |
| 83 | broken-ref | 50 | 0 | 0 | 639 | 639 | fix now (top quartile of real-code hits) |
| 0c | OTHER | 50 | 0 | 0 | 638 | 638 | fix now (top quartile of real-code hits) |
| bf | xF | 50 | 0 | 0 | 629 | 629 | fix now (top quartile of real-code hits) |
| e9 | OTHER | 3 | 0 | 3 | 627 | 627 | fix now (top quartile of real-code hits) |
| 0f | OTHER | 50 | 0 | 0 | 623 | 623 | fix now (top quartile of real-code hits) |
| 1a | broken-ref | 50 | 0 | 0 | 616 | 616 | fix now (top quartile of real-code hits) |
| f1 | OTHER | 2 | 0 | 2 | 562 | 562 | fix now (top quartile of real-code hits) |
| 12 | broken-ref | 50 | 50 | 0 | 560 | 560 | fix now (top quartile of real-code hits) |
| ef | OTHER | 50 | 0 | 38 | 560 | 560 | fix now (top quartile of real-code hits) |
| e3 | broken-ref | 50 | 0 | 35 | 548 | 548 | fix now (top quartile of real-code hits) |
| e1 | OTHER | 2 | 0 | 2 | 544 | 544 | fix now (top quartile of real-code hits) |
| ed | OTHER | 3 | 0 | 3 | 537 | 537 | fix now (top quartile of real-code hits) |
| 14 | broken-ref | 50 | 0 | 0 | 535 | 535 | fix now (top quartile of real-code hits) |
| 0b | broken-ref | 50 | 0 | 0 | 531 | 531 | fix now (top quartile of real-code hits) |
| 8f | OTHER | 50 | 0 | 0 | 524 | 524 | fix later |
| 87 | broken-ref | 50 | 0 | 0 | 515 | 515 | fix later |
| 1f | OTHER | 50 | 0 | 0 | 513 | 513 | fix later |
| 9f | OTHER | 50 | 0 | 0 | 511 | 511 | fix later |
| 1c | broken-ref | 50 | 0 | 0 | 498 | 498 | fix later |
| a3 | broken-ref | 50 | 0 | 0 | 490 | 490 | fix later |
| 7f | OTHER | 50 | 0 | 39 | 487 | 487 | fix later |
| ab | broken-ref | 50 | 0 | 32 | 485 | 485 | fix later |
| 3f | OTHER | 50 | 14 | 15 | 482 | 482 | fix later |
| eb | broken-ref | 50 | 0 | 30 | 481 | 481 | fix later |
| 5a | OTHER | 50 | 0 | 0 | 476 | 476 | fix later |
| 89 | OTHER | 28 | 0 | 0 | 471 | 471 | fix later |
| 62 | broken-ref | 50 | 50 | 0 | 464 | 464 | fix later |
| 9e | broken-ref | 50 | 0 | 0 | 451 | 451 | fix later |
| 1b | broken-ref | 50 | 0 | 0 | 450 | 450 | fix later |
| 3a | broken-ref | 50 | 0 | 0 | 450 | 450 | fix later |
| 23 | broken-ref | 50 | 10 | 11 | 444 | 444 | fix later |
| 2b | broken-ref | 50 | 0 | 0 | 439 | 439 | fix later |
| e7 | broken-ref | 50 | 0 | 34 | 437 | 437 | fix later |
| bb | broken-ref | 50 | 0 | 0 | 437 | 437 | fix later |
| f2 | JAM | 50 | 50 | 0 | 435 | 435 | fix later |
| df | OTHER | 50 | 0 | 0 | 433 | 433 | fix later |
| f3 | broken-ref | 50 | 0 | 33 | 427 | 427 | fix later |
| 13 | broken-ref | 50 | 0 | 0 | 427 | 427 | fix later |
| a7 | broken-ref | 50 | 0 | 0 | 425 | 425 | fix later |
| d7 | broken-ref | 50 | 0 | 0 | 420 | 420 | fix later |
| 17 | broken-ref | 50 | 0 | 0 | 414 | 414 | fix later |
| 7a | OTHER | 50 | 0 | 0 | 414 | 414 | fix later |
| 8b | broken-ref | 50 | 0 | 24 | 409 | 409 | fix later |
| e5 | OTHER | 3 | 0 | 3 | 406 | 406 | fix later |
| 52 | broken-ref | 50 | 50 | 0 | 400 | 400 | fix later |
| 3b | broken-ref | 50 | 13 | 11 | 398 | 398 | fix later |
| af | xF | 50 | 0 | 0 | 396 | 396 | fix later |
| 6b | broken-ref | 50 | 0 | 50 | 394 | 394 | fix later |
| 57 | broken-ref | 50 | 0 | 0 | 394 | 394 | fix later |
| 63 | broken-ref | 50 | 0 | 34 | 389 | 389 | fix later |
| d2 | broken-ref | 50 | 50 | 0 | 374 | 374 | fix later |
| 9b | broken-ref | 50 | 0 | 0 | 372 | 372 | fix later |
| 5f | OTHER | 50 | 0 | 0 | 371 | 371 | fix later |
| 42 | broken-ref | 50 | 50 | 0 | 369 | 369 | fix later |
| 74 | broken-ref | 50 | 0 | 0 | 369 | 369 | fix later |
| dc | OTHER | 50 | 0 | 0 | 367 | 367 | fix later |
| 47 | broken-ref | 50 | 0 | 0 | 366 | 366 | fix later |
| c3 | broken-ref | 50 | 0 | 0 | 366 | 366 | fix later |
| 7c | OTHER | 50 | 0 | 0 | 365 | 365 | fix later |
| 3c | OTHER | 40 | 0 | 0 | 362 | 362 | fix later |
| 7b | broken-ref | 50 | 0 | 36 | 361 | 361 | fix later |
| 9c | broken-ref | 50 | 0 | 0 | 361 | 361 | fix later |
| da | OTHER | 50 | 0 | 0 | 361 | 361 | fix later |
| 27 | broken-ref | 50 | 19 | 9 | 360 | 360 | fix later |
| 34 | OTHER | 39 | 0 | 0 | 359 | 359 | fix later |
| 53 | broken-ref | 50 | 0 | 0 | 358 | 358 | fix later |
| 77 | broken-ref | 50 | 0 | 38 | 357 | 357 | fix later |
| 97 | broken-ref | 50 | 0 | 0 | 355 | 355 | fix later |
| b3 | broken-ref | 50 | 0 | 0 | 354 | 354 | fix later |
| 2f | OTHER | 50 | 10 | 14 | 351 | 351 | fix later |
| cf | OTHER | 50 | 0 | 0 | 351 | 351 | fix later |
| d3 | broken-ref | 50 | 0 | 0 | 347 | 347 | fix later |
| 93 | broken-ref | 50 | 0 | 0 | 339 | 339 | fix later |
| 5b | broken-ref | 50 | 0 | 0 | 335 | 335 | fix later |
| 92 | broken-ref | 50 | 50 | 0 | 333 | 333 | fix later |
| db | OTHER | 50 | 0 | 0 | 331 | 331 | fix later |
| 4f | OTHER | 50 | 0 | 0 | 330 | 330 | fix later |
| 43 | broken-ref | 50 | 0 | 0 | 328 | 328 | fix later |
| 79 | OTHER | 2 | 0 | 2 | 325 | 325 | fix later |
| 6f | OTHER | 50 | 0 | 42 | 323 | 323 | fix later |
| cb | OTHER | 50 | 0 | 0 | 320 | 320 | fix later |
| b2 | broken-ref | 50 | 50 | 0 | 317 | 317 | fix later |
| 4b | broken-ref | 50 | 0 | 46 | 307 | 307 | fix later |
| 5c | OTHER | 50 | 0 | 0 | 305 | 305 | fix later |
| 32 | broken-ref | 50 | 50 | 0 | 298 | 298 | fix later |
| 72 | JAM | 50 | 50 | 0 | 298 | 298 | fix later |
| b7 | broken-ref | 50 | 0 | 0 | 297 | 297 | fix later |
| 67 | broken-ref | 50 | 0 | 36 | 291 | 291 | fix later |
| c7 | broken-ref | 50 | 0 | 0 | 274 | 274 | fix later |
| 64 | broken-ref | 50 | 0 | 0 | 272 | 272 | fix later |
| 37 | broken-ref | 50 | 10 | 12 | 269 | 269 | fix later |
| 33 | broken-ref | 50 | 12 | 11 | 268 | 268 | fix later |
| 73 | broken-ref | 50 | 0 | 40 | 263 | 263 | fix later |

## Context: most frequent byte values in the HD image


## Label rules

- `drop`: zero static hits in every image - no evidence real
  software executes it; document as suite-only (B3: recommend drop).
- `fix now`: nonzero hits in the top quartile of the nonzero-hit
  population - strongest real-world relevance signal.
- `fix later`: nonzero hits, below the top quartile.

