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
| TR52.hdv | E:/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/disks/Total Replay v5.2.hdv | 33553920 | 0c0e5bd92387d7041ec131e6b003dc400cb0bb4ad39f2859f71ed95b0fec9f47 |
| MiniReplay.dsk | E:/MiSTer/Apple-II_FPGAdev/Apple-II-Verilog_MiSTer/disks/Mini Replay v1.1.dsk | 143360 | aceff64159d3f90af5d8071001e34ae39a838c2812384aafefc7b02fea7e3fd1 |
| apple2e.rom | E:/MiSTer/Apple-II_FPGAdev/Apple-II_MiSTer_newsdee/rtl/roms/apple2e.mif | 15698 | 7c16742ab427f46791b2915876266bb62e4c86a459fc42f021b9a9baebce6cd6 |

## Ranked table (all 105 both-fail ops)

| op | class | both-fail | C5 | C6 | hits(TR52.hdv) | hits(MiniReplay.dsk) | hits(apple2e.rom) | total | label |
|----|-------|-----------|----|----|------------|------------|------------|-----------|-------------|
| ff | OTHER | 50 | 0 | 29 | 551448 | 1245 | 118 | 552811 | fix now (top quartile of real-code hits) |
| 7f | OTHER | 50 | 0 | 39 | 317475 | 487 | 47 | 318009 | fix now (top quartile of real-code hits) |
| 02 | broken-ref | 50 | 50 | 0 | 279869 | 1195 | 152 | 281216 | fix now (top quartile of real-code hits) |
| 03 | broken-ref | 50 | 0 | 0 | 250412 | 1015 | 164 | 251591 | fix now (top quartile of real-code hits) |
| 04 | OTHER | 50 | 0 | 0 | 241785 | 919 | 152 | 242856 | fix now (top quartile of real-code hits) |
| 07 | broken-ref | 50 | 0 | 0 | 191113 | 776 | 73 | 191962 | fix now (top quartile of real-code hits) |
| 22 | broken-ref | 50 | 50 | 0 | 187119 | 755 | 32 | 187906 | fix now (top quartile of real-code hits) |
| 0c | OTHER | 50 | 0 | 0 | 185963 | 638 | 41 | 186642 | fix now (top quartile of real-code hits) |
| 14 | broken-ref | 50 | 0 | 0 | 182317 | 535 | 29 | 182881 | fix now (top quartile of real-code hits) |
| 12 | broken-ref | 50 | 50 | 0 | 151010 | 560 | 42 | 151612 | fix now (top quartile of real-code hits) |
| 0f | OTHER | 50 | 0 | 0 | 150737 | 623 | 46 | 151406 | fix now (top quartile of real-code hits) |
| 33 | broken-ref | 50 | 12 | 11 | 134419 | 268 | 10 | 134697 | fix now (top quartile of real-code hits) |
| 83 | broken-ref | 50 | 0 | 0 | 127480 | 639 | 27 | 128146 | fix now (top quartile of real-code hits) |
| 1f | OTHER | 50 | 0 | 0 | 119272 | 513 | 32 | 119817 | fix now (top quartile of real-code hits) |
| 3f | OTHER | 50 | 14 | 15 | 115024 | 482 | 22 | 115528 | fix now (top quartile of real-code hits) |
| 1c | broken-ref | 50 | 0 | 0 | 113172 | 498 | 21 | 113691 | fix now (top quartile of real-code hits) |
| fc | OTHER | 50 | 0 | 0 | 111267 | 689 | 34 | 111990 | fix now (top quartile of real-code hits) |
| 87 | broken-ref | 50 | 0 | 0 | 110192 | 515 | 12 | 110719 | fix now (top quartile of real-code hits) |
| bb | broken-ref | 50 | 0 | 0 | 109195 | 437 | 11 | 109643 | fix now (top quartile of real-code hits) |
| 13 | broken-ref | 50 | 0 | 0 | 107805 | 427 | 34 | 108266 | fix now (top quartile of real-code hits) |
| 0b | broken-ref | 50 | 0 | 0 | 107146 | 531 | 28 | 107705 | fix now (top quartile of real-code hits) |
| 77 | broken-ref | 50 | 0 | 38 | 104855 | 357 | 5 | 105217 | fix now (top quartile of real-code hits) |
| 42 | broken-ref | 50 | 50 | 0 | 98742 | 369 | 18 | 99129 | fix now (top quartile of real-code hits) |
| 9f | OTHER | 50 | 0 | 0 | 98226 | 511 | 31 | 98768 | fix now (top quartile of real-code hits) |
| bf | xF | 50 | 0 | 0 | 97715 | 629 | 4 | 98348 | fix now (top quartile of real-code hits) |
| f7 | broken-ref | 50 | 0 | 36 | 95435 | 663 | 43 | 96141 | fix now (top quartile of real-code hits) |
| 8f | OTHER | 50 | 0 | 0 | 95468 | 524 | 9 | 96001 | fix later |
| 7c | OTHER | 50 | 0 | 0 | 95464 | 365 | 9 | 95838 | fix later |
| 43 | broken-ref | 50 | 0 | 0 | 93289 | 328 | 28 | 93645 | fix later |
| 52 | broken-ref | 50 | 50 | 0 | 92529 | 400 | 68 | 92997 | fix later |
| 3c | OTHER | 40 | 0 | 0 | 91373 | 362 | 37 | 91772 | fix later |
| 32 | broken-ref | 50 | 50 | 0 | 90211 | 298 | 19 | 90528 | fix later |
| 3b | broken-ref | 50 | 13 | 11 | 87412 | 398 | 17 | 87827 | fix later |
| 1a | broken-ref | 50 | 0 | 0 | 86687 | 616 | 31 | 87334 | fix later |
| 1b | broken-ref | 50 | 0 | 0 | 86326 | 450 | 19 | 86795 | fix later |
| fd | OTHER | 4 | 0 | 4 | 85135 | 687 | 77 | 85899 | fix later |
| 23 | broken-ref | 50 | 10 | 11 | 85101 | 444 | 29 | 85574 | fix later |
| 34 | OTHER | 39 | 0 | 0 | 84820 | 359 | 19 | 85198 | fix later |
| b3 | broken-ref | 50 | 0 | 0 | 82910 | 354 | 10 | 83274 | fix later |
| 17 | broken-ref | 50 | 0 | 0 | 82403 | 414 | 21 | 82838 | fix later |
| 64 | broken-ref | 50 | 0 | 0 | 82540 | 272 | 21 | 82833 | fix later |
| 3a | broken-ref | 50 | 0 | 0 | 81372 | 450 | 32 | 81854 | fix later |
| 4f | OTHER | 50 | 0 | 0 | 80476 | 330 | 57 | 80863 | fix later |
| f9 | OTHER | 1 | 0 | 1 | 77652 | 695 | 46 | 78393 | fix later |
| 72 | JAM | 50 | 50 | 0 | 77549 | 298 | 15 | 77862 | fix later |
| cf | OTHER | 50 | 0 | 0 | 77372 | 351 | 17 | 77740 | fix later |
| 37 | broken-ref | 50 | 10 | 12 | 77014 | 269 | 7 | 77290 | fix later |
| 27 | broken-ref | 50 | 19 | 9 | 76897 | 360 | 24 | 77281 | fix later |
| fa | OTHER | 50 | 0 | 0 | 76344 | 707 | 20 | 77071 | fix later |
| 47 | broken-ref | 50 | 0 | 0 | 76422 | 366 | 18 | 76806 | fix later |
| 74 | broken-ref | 50 | 0 | 0 | 76277 | 369 | 21 | 76667 | fix later |
| 62 | broken-ref | 50 | 50 | 0 | 76177 | 464 | 17 | 76658 | fix later |
| df | OTHER | 50 | 0 | 0 | 75429 | 433 | 24 | 75886 | fix later |
| 53 | broken-ref | 50 | 0 | 0 | 75475 | 358 | 46 | 75879 | fix later |
| 89 | OTHER | 28 | 0 | 0 | 75185 | 471 | 15 | 75671 | fix later |
| 6f | OTHER | 50 | 0 | 42 | 74775 | 323 | 18 | 75116 | fix later |
| 9c | broken-ref | 50 | 0 | 0 | 74695 | 361 | 35 | 75091 | fix later |
| 73 | broken-ref | 50 | 0 | 40 | 74780 | 263 | 10 | 75053 | fix later |
| 67 | broken-ref | 50 | 0 | 36 | 73322 | 291 | 33 | 73646 | fix later |
| fb | broken-ref | 50 | 0 | 34 | 72236 | 789 | 101 | 73126 | fix later |
| e1 | OTHER | 2 | 0 | 2 | 72550 | 544 | 27 | 73121 | fix later |
| a3 | broken-ref | 50 | 0 | 0 | 72568 | 490 | 11 | 73069 | fix later |
| 92 | broken-ref | 50 | 50 | 0 | 72668 | 333 | 12 | 73013 | fix later |
| 2b | broken-ref | 50 | 0 | 0 | 72496 | 439 | 13 | 72948 | fix later |
| 9e | broken-ref | 50 | 0 | 0 | 71705 | 451 | 47 | 72203 | fix later |
| c3 | broken-ref | 50 | 0 | 0 | 71407 | 366 | 20 | 71793 | fix later |
| 7a | OTHER | 50 | 0 | 0 | 71175 | 414 | 12 | 71601 | fix later |
| 63 | broken-ref | 50 | 0 | 34 | 71179 | 389 | 14 | 71582 | fix later |
| ab | broken-ref | 50 | 0 | 32 | 70815 | 485 | 23 | 71323 | fix later |
| 79 | OTHER | 2 | 0 | 2 | 70665 | 325 | 19 | 71009 | fix later |
| d7 | broken-ref | 50 | 0 | 0 | 70486 | 420 | 27 | 70933 | fix later |
| 93 | broken-ref | 50 | 0 | 0 | 70082 | 339 | 16 | 70437 | fix later |
| 57 | broken-ref | 50 | 0 | 0 | 69984 | 394 | 12 | 70390 | fix later |
| d2 | broken-ref | 50 | 50 | 0 | 69756 | 374 | 31 | 70161 | fix later |
| f3 | broken-ref | 50 | 0 | 33 | 69176 | 427 | 30 | 69633 | fix later |
| f1 | OTHER | 2 | 0 | 2 | 68846 | 562 | 24 | 69432 | fix later |
| e7 | broken-ref | 50 | 0 | 34 | 68698 | 437 | 48 | 69183 | fix later |
| 2f | OTHER | 50 | 10 | 14 | 68706 | 351 | 14 | 69071 | fix later |
| 5c | OTHER | 50 | 0 | 0 | 68382 | 305 | 17 | 68704 | fix later |
| ef | OTHER | 50 | 0 | 38 | 67818 | 560 | 31 | 68409 | fix later |
| 8b | broken-ref | 50 | 0 | 24 | 67903 | 409 | 16 | 68328 | fix later |
| 5a | OTHER | 50 | 0 | 0 | 66831 | 476 | 10 | 67317 | fix later |
| f2 | JAM | 50 | 50 | 0 | 66750 | 435 | 48 | 67233 | fix later |
| 5f | OTHER | 50 | 0 | 0 | 66352 | 371 | 31 | 66754 | fix later |
| c7 | broken-ref | 50 | 0 | 0 | 66445 | 274 | 21 | 66740 | fix later |
| d3 | broken-ref | 50 | 0 | 0 | 66271 | 347 | 32 | 66650 | fix later |
| e9 | OTHER | 3 | 0 | 3 | 65912 | 627 | 71 | 66610 | fix later |
| af | xF | 50 | 0 | 0 | 65862 | 396 | 14 | 66272 | fix later |
| dc | OTHER | 50 | 0 | 0 | 65826 | 367 | 18 | 66211 | fix later |
| 9b | broken-ref | 50 | 0 | 0 | 65097 | 372 | 76 | 65545 | fix later |
| 6b | broken-ref | 50 | 0 | 50 | 64718 | 394 | 14 | 65126 | fix later |
| e3 | broken-ref | 50 | 0 | 35 | 64456 | 548 | 44 | 65048 | fix later |
| b7 | broken-ref | 50 | 0 | 0 | 64678 | 297 | 25 | 65000 | fix later |
| b2 | broken-ref | 50 | 50 | 0 | 64565 | 317 | 13 | 64895 | fix later |
| 4b | broken-ref | 50 | 0 | 46 | 64440 | 307 | 15 | 64762 | fix later |
| 7b | broken-ref | 50 | 0 | 36 | 64165 | 361 | 66 | 64592 | fix later |
| 97 | broken-ref | 50 | 0 | 0 | 64200 | 355 | 9 | 64564 | fix later |
| e5 | OTHER | 3 | 0 | 3 | 63516 | 406 | 72 | 63994 | fix later |
| a7 | broken-ref | 50 | 0 | 0 | 63315 | 425 | 16 | 63756 | fix later |
| ed | OTHER | 3 | 0 | 3 | 62134 | 537 | 40 | 62711 | fix later |
| db | OTHER | 50 | 0 | 0 | 58936 | 331 | 38 | 59305 | fix later |
| da | OTHER | 50 | 0 | 0 | 58791 | 361 | 41 | 59193 | fix later |
| eb | broken-ref | 50 | 0 | 30 | 57567 | 481 | 47 | 58095 | fix later |
| 5b | broken-ref | 50 | 0 | 0 | 55801 | 335 | 7 | 56143 | fix later |
| cb | OTHER | 50 | 0 | 0 | 53877 | 320 | 24 | 54221 | fix later |

## Context: most frequent byte values in the HD image

| byte | hits | note |
|------|------|------|
| 00 | 5578219 |  |
| 80 | 1247187 |  |
| ff | 551448 | in both-fail population |
| aa | 374236 |  |
| 01 | 368358 |  |
| 20 | 342691 |  |
| 7f | 317475 | in both-fail population |
| d5 | 291886 |  |
| 02 | 279869 | in both-fail population |
| 03 | 250412 | in both-fail population |
| 08 | 247967 |  |
| 10 | 246679 |  |
| 04 | 241785 | in both-fail population |
| 55 | 220805 |  |
| 2a | 216897 |  |
| a0 | 208265 |  |
| 11 | 200445 |  |
| 40 | 198567 |  |
| 06 | 198326 |  |
| 07 | 191113 | in both-fail population |

## Label rules

- `drop`: zero static hits in every image - no evidence real
  software executes it; document as suite-only (B3: recommend drop).
- `fix now`: nonzero hits in the top quartile of the nonzero-hit
  population - strongest real-world relevance signal.
- `fix later`: nonzero hits, below the top quartile.

