# AutoIt ChessCore

**AutoIt ChessCore** is a standalone native chess rules core written in **AutoIt 3.3.18.0**.

It is designed to provide a self-contained foundation for chess applications built with AutoIt, including chess bots, GUI applications, board-state management, move validation, automation systems, and chess testing tools.

The core is intentionally independent from previous ChessCore generations and does not require a Phase 9 runtime dependency.

---

## Overview

AutoIt ChessCore separates the chess rules layer from higher-level components such as:

* User interfaces
* Chess engines and search
* Computer vision / board recognition
* Automation and bot logic
* Application-specific game management

Its responsibility is the **correct representation and manipulation of chess positions and rules**.

The current implementation is built around a single coherent position state, compact internal move encoding, incremental Make/Unmake operations, committed game history, and Zobrist position hashing.

---

## Key Features

* Native **AutoIt 3.3.18.0**
* Standalone chess rules core
* No runtime dependency on earlier ChessCore generations
* 64-square mailbox board representation
* Compact 20-bit internal move representation
* UCI-compatible public move interface
* FEN parsing, validation, and serialization
* Legal move generation
* Check detection
* Checkmate detection
* Stalemate detection
* Castling
* En Passant
* Promotion
* Make / Unmake move system
* Public Push / Pop game-history API
* Dynamic move-stack growth
* Separate trial move stack and committed game history
* Incremental Zobrist hashing
* Logical 64-bit position identity using Hi32 + Lo32
* Repetition tracking
* Fifty-move detection
* Insufficient-material detection
* Perft
* Perft Divide
* Position/state validation
* Transaction-safe state updates

---

## Position Representation

The board is stored as a fixed 64-element array:

```autoit
Global $g_Board[64]
```

Squares are represented using a linear index from `0` to `63`, with helper functions for conversion between board coordinates and square indexes.

The core intentionally uses a **Mailbox[64]** representation rather than bitboards. This keeps the implementation explicit and maintainable while fitting the characteristics of the AutoIt runtime.

---

## Piece Representation

Pieces use fixed numeric identifiers:

```text
0  = Empty

1  = White Pawn
2  = White Knight
3  = White Bishop
4  = White Rook
5  = White Queen
6  = White King

7  = Black Pawn
8  = Black Knight
9  = Black Bishop
10 = Black Rook
11 = Black Queen
12 = Black King
```

The same mapping is used consistently throughout the core.

---

## Complete Position State

A chess position is more than the piece placement.

The core maintains:

* Board state
* Side to move
* Castling rights
* En Passant square
* Halfmove clock
* Fullmove number
* White king square
* Black king square

King locations are cached so that king-related legality checks do not require a full board scan every time.

---

## FEN Support

The core provides:

```autoit
ChessCore_SetFEN()
ChessCore_GetFEN()
ChessCore_ValidateFEN()
```

`ChessCore_SetFEN()` parses a complete FEN position and updates the current state only after successful validation.

`ChessCore_GetFEN()` serializes the current position back to FEN.

`ChessCore_ValidateFEN()` validates a FEN without modifying the live position.

The parser validates more than basic syntax. It also checks structural and positional constraints such as king counts, pawn limits, piece limits, side to move, king separation, castling consistency, En Passant state, and move counters.

Invalid FEN input is handled transactionally: a failed parse does not partially overwrite the active position.

---

## Case-Sensitive FEN Parsing

FEN distinguishes piece color by case:

```text
P = White Pawn
p = Black Pawn
```

Because AutoIt's string-based `Switch` matching is not suitable for this distinction, piece parsing uses explicit case-sensitive comparisons. The same principle is applied to castling-rights parsing.

---

## Attack Detection

The core contains dedicated attack detection for:

* Pawns
* Knights
* Kings
* Bishops
* Rooks
* Queens

Sliding pieces are traced square by square until the first occupied square is reached.

This attack system is reused by move legality, Check detection, Castling validation, FEN validation, and En Passant king-safety checks.

---

## Move Generation

Move generation is performed in two stages.

### 1. Pseudo-Legal Moves

The core first generates moves based on piece movement rules.

This includes:

* Pawn moves
* Double pawn pushes
* Captures
* En Passant
* Promotions
* Knight moves
* Bishop moves
* Rook moves
* Queen moves
* King moves
* Castling

Sliding pieces stop at the first occupied square.

### 2. Legal Move Filtering

Each pseudo-legal move is tested by:

```text
Generate move
      ↓
Make move
      ↓
Check own king
      ↓
Unmake move
```

A move is accepted only if the moving side's king is not left in check.

The public API returns legal moves using the established UCI-string contract.

---

## Packed Move Representation

Internally, moves are not stored as UCI strings.

A move occupies **20 bits**:

```text
Bits  0..5   = From square
Bits  6..11  = To square
Bits 12..14  = Promotion type
Bits 15..19  = Move flags
```

Move flags include:

```text
Normal
Capture
Double Pawn
Castling
En Passant
Promotion
```

This keeps internal move operations compact while allowing the public API to remain UCI-compatible.

---

## Make / Unmake

The internal move system is built around:

```autoit
Core_MakeMove()
Core_UnmakeMove()
```

`Core_MakeMove()` updates the board and all related state, including:

* Captures
* Promotions
* En Passant
* Castling rook movement
* Castling rights
* Halfmove clock
* Fullmove number
* En Passant square
* Side to move
* King caches
* Incremental position hash

The complete previous state is stored in the move stack so that `Core_UnmakeMove()` can restore the position exactly.

---

## Dynamic Move Stack

The internal undo stack starts with a fixed capacity and automatically expands when necessary.

Each stored MoveState contains the information required for exact restoration, including the move, captured piece, castling rights, En Passant state, clocks, hash state, and king locations.

The stack capacity is doubled when it becomes full.

---

## Trial Moves vs. Committed Game History

The core deliberately maintains two separate concepts:

### Trial Move Stack

Used by operations such as:

* Legal move generation
* Perft
* Make/Unmake
* Search-style temporary positions

### Committed Game History

Used by actual game moves and repetition tracking.

Trial operations never write to committed game history. This prevents internal testing or search operations from corrupting real game history.

---

## Public Push / Pop API

The public game-state interface provides:

```autoit
ChessCore_PushMove()
ChessCore_PushMoveEx()
ChessCore_PopMove()
```

`ChessCore_PushMove()` validates the requested move, applies it, and records it in committed history.

`ChessCore_PopMove()` restores the previous committed position through the internal Unmake mechanism.

---

## Castling

All four standard castling moves are supported:

```text
White O-O
White O-O-O
Black O-O
Black O-O-O
```

The generator checks:

* Castling rights
* King and rook placement
* Empty transit squares
* Whether the king is currently in check
* Whether the king crosses an attacked square
* Whether the destination square is attacked

Castling is represented using a dedicated move flag and the rook movement is handled during Make/Unmake.

---

## En Passant

En Passant is supported both as a legal move and as part of position identity.

The core goes beyond checking whether an En Passant square exists. It can determine whether a **legal En Passant capture actually exists**, including king-safety considerations.

This is important for correct repetition identity and Zobrist hashing.

---

## Promotion

Pawn promotion supports all four standard promotion pieces:

```text
Queen
Rook
Bishop
Knight
```

Both normal promotion and capture-promotion are generated.

Promotion is represented in the packed move format and converted to the correct side-specific piece during MakeMove.

---

## Position Hashing

AutoIt bitwise operations are 32-bit, so the core represents its logical 64-bit Zobrist position identity using two explicit components:

```text
HashHi
HashLo
```

This avoids treating AutoIt's bitwise operations as native 64-bit arithmetic.

The hash incorporates the position components relevant to chess identity, including:

* Piece placement
* Side to move
* Castling rights
* Relevant En Passant state

---

## Incremental Zobrist Updates

The position hash is updated incrementally during MakeMove instead of rebuilding the entire board hash after every move.

Changed components are XORed out and in as the position changes. The previous hash is stored in MoveState and restored directly during UnmakeMove.

This provides a fast position-identity mechanism suitable for repetition tracking and repeated Make/Unmake workloads.

---

## En Passant Position Identity

A raw En Passant square is not necessarily sufficient to make two positions legally distinct.

The core therefore normalizes En Passant hashing so that the EP file is included in the hash only when a legal En Passant capture exists for the side to move.

If no legal En Passant capture exists, the EP information is ignored for position identity.

---

## Game Status

The core provides:

```autoit
ChessCore_IsCheck()
ChessCore_IsCheckmate()
ChessCore_IsStalemate()
ChessCore_IsDraw()
ChessCore_GetGameStatus()
ChessCore_GetOutcome()
```

Supported game-status results include:

```text
check
checkmate
stalemate
draw_fifty
draw_insufficient
draw_repetition
normal
```

The corresponding outcome can be:

```text
white_win
black_win
draw
none
```

---

## Draw Detection

The current core detects:

### Fifty-Move Rule

A draw is detected when:

```text
HalfmoveClock >= 100
```

### Insufficient Material

The implementation recognizes several basic insufficient-material cases, including king-only positions, king plus one minor piece versus king, and bishops confined to the same square color.

### Threefold Repetition

Repetition is detected from the committed game history using the current position hash.

---

## Perft

Perft is an important validation mechanism for chess rule implementations.

The core provides:

```autoit
ChessCore_Perft()
ChessCore_PerftDivide()
```

Perft uses the same core path as legal move generation:

```text
Generate Legal Moves
        ↓
Make Move
        ↓
Recursive Perft
        ↓
Unmake Move
```

This means Perft exercises the actual move-generation and state-transition machinery rather than a separate test implementation.

`ChessCore_PerftDivide()` provides node counts broken down by root move, which is useful when diagnosing a Perft mismatch.

---

## State Validation and Transaction Safety

The core is designed around safe state transitions.

Invalid operations are intended to leave the current state unchanged.

This applies to areas including:

* Invalid FEN input
* Invalid side-to-move input
* Invalid castling input
* Invalid En Passant input
* Illegal moves

FEN parsing is performed into temporary state before committing it, and the setter functions rebuild the hash and establish a new history baseline when they intentionally replace the current position.

---

## Public API

The public interface follows the `ChessCore_*` naming convention.

Representative functions include:

```autoit
ChessCore_Init()
ChessCore_NewGame()
ChessCore_Reset()

ChessCore_SetFEN()
ChessCore_GetFEN()
ChessCore_ValidateFEN()

ChessCore_GetPiece()
ChessCore_SetPiece()
ChessCore_SetBoardSnapshot()
ChessCore_GetBoardSnapshot()

ChessCore_GenerateLegalMoves()
ChessCore_IsLegalMove()
ChessCore_IsLegalMoveEx()

ChessCore_PushMove()
ChessCore_PushMoveEx()
ChessCore_PopMove()

ChessCore_IsCheck()
ChessCore_IsCheckmate()
ChessCore_IsStalemate()
ChessCore_IsDraw()

ChessCore_GetGameStatus()
ChessCore_GetOutcome()

ChessCore_GetPositionHash()
ChessCore_GetPositionHashHi()
ChessCore_GetPositionHashLo()

ChessCore_CountRepetitions()

ChessCore_Perft()
ChessCore_PerftDivide()
```

The implementation also retains selected internal compatibility names from the earlier API model while routing them into the unified implementation instead of maintaining a second state system.

---

## Validation Suite

The project includes an adversarial test harness:

**Phase 10 — The Last Judgment / Omega Torture Suite V2 — Forensic**

The test suite is designed to stress important invariants of the core, including:

* FEN parse/serialize transaction safety
* Legal move generation
* Move uniqueness
* Standard Perft positions
* Packed-move bijection
* Make/Unmake exact restoration
* Dynamic move-stack growth
* Committed-history correctness
* Trial/history isolation
* Incremental hash consistency
* En Passant identity normalization
* Castling semantics
* Promotion semantics
* Illegal-input immutability
* Repetition handling
* Deterministic random-play endurance
* Repeated Make/Unmake stress

The current test harness directly includes:

```autoit
#include "AutoIt_ChessCore.au3"
```

and is intended to exercise the actual public and internal paths of the Core.

The suite includes standard chess Perft reference positions such as the initial position, Kiwipete, and Position 3.

---

## Design Philosophy

AutoIt ChessCore is intentionally focused on one responsibility:

> **Provide a robust, self-contained chess rules and position-management core for AutoIt.**

It is not intended to replace a chess evaluation engine such as Stockfish.

A typical architecture can therefore look like:

```text
                +----------------------+
                |     Chess GUI        |
                +----------+-----------+
                           |
                +----------v-----------+
                |    Application /     |
                |    Bot / Automation  |
                +----------+-----------+
                           |
                +----------v-----------+
                |   Chess Engine /     |
                |      Search          |
                +----------+-----------+
                           |
                +----------v-----------+
                |   AutoIt ChessCore   |
                |-----------------------|
                | Board / FEN / UCI     |
                | Legal Moves           |
                | Make / Unmake         |
                | Hash / History        |
                | Game Status           |
                +-----------------------+
```

This separation allows different front ends and higher-level systems to share the same chess rules layer.

---

## Project Status

`AutoIt_ChessCore.au3` is a standalone unified implementation for **AutoIt 3.3.18.0**.

Its architecture is based on:

* A single position state
* Mailbox[64] board storage
* Packed internal moves
* Make/Unmake state transitions
* Separate committed history
* Incremental Zobrist position identity
* Shared legal-move and Perft paths
* Public FEN and UCI interfaces

The project is intended to evolve as an open-source chess infrastructure component for the AutoIt ecosystem.

---

## License

AutoIt ChessCore is licensed under the **Apache License 2.0**.

See the [LICENSE](https://github.com/hamidic911/AutoIt-ChessCore/blob/main/LICENSE) file for the complete license text.
