#NoTrayIcon
#AutoIt3Wrapper_Run_Au3Check=n
#AutoIt3Wrapper_UseX64=n

; =============================================================================
; AUTOIT CHESSCORE
; THE LAST JUDGMENT / ADVERSARIAL FORENSIC TEST SUITE
; =============================================================================
; Purpose:
;   This is not a normal unit test. It is an adversarial validation harness
;   designed to attack every important invariant of the Phase-10 core:
;
;     * FEN parse/serialize transaction safety
;     * legal move generation and uniqueness
;     * standard perft monuments
;     * packed-move bijection
;     * Make/Unmake exact restoration
;     * dynamic move-stack growth
;     * committed-history correctness
;     * trial/history isolation
;     * incremental Zobrist vs rebuild-through-FEN
;     * normalized En Passant identity
;     * castling / EP / promotion semantics
;     * illegal-input non-mutation
;     * long deterministic random-play endurance
;     * repeated random Make/Unmake avalanche
;
; IMPORTANT:
;   Place beside the AutoIt ChessCore source. Change only the include if your
;   filename differs.
; =============================================================================
#include "AutoIt_ChessCore.au3"

; ----------------------------- Configuration ---------------------------------
Global Const $RUN_START_D5 = True
Global Const $RUN_KIWIPETE_D4 = True
Global Const $RUN_POSITION3_D5 = True
Global Const $RANDOM_GAMES = 50
Global Const $RANDOM_PLIES_PER_GAME = 220
Global Const $TRIAL_AVALANCHE_DEPTH = 520
Global Const $HISTORY_AVALANCHE_PLIES = 300
Global Const $PACKED_RANDOM_CASES = 25000
Global Const $HASH_RANDOM_SAMPLES = 250
Global Const $CHECK_EVERY_RANDOM_PLY = 11
Global Const $HASH_REBUILD_EVERY_RANDOM_PLY = 19

Global $g_Total = 0
Global $g_Pass = 0
Global $g_Fail = 0
Global $g_FirstFailure = ""
Global $g_Seed = 20260910
Global $g_Log = @ScriptDir & "\Phase10_LastJudgment_Failures.log"

FileDelete($g_Log)

; ----------------------------- Reporting ------------------------------------
Func Say($s)
    ConsoleWrite($s & @CRLF)
EndFunc

Func Check($sName, $bOK, $sDetail = "")
    $g_Total += 1
    If $bOK Then
        $g_Pass += 1
        ConsoleWrite("[PASS] " & $sName & @CRLF)
    Else
        $g_Fail += 1
        If $g_FirstFailure = "" Then $g_FirstFailure = $sName & " :: " & $sDetail
        ConsoleWrite("[FAIL] " & $sName & " :: " & $sDetail & @CRLF)
        FileWrite($g_Log, "[FAIL] " & $sName & " :: " & $sDetail & @CRLF)
    EndIf
EndFunc

Func SilentCheck($sName, $bOK, $sDetail = "")
    $g_Total += 1
    If $bOK Then
        $g_Pass += 1
    Else
        $g_Fail += 1
        If $g_FirstFailure = "" Then $g_FirstFailure = $sName & " :: " & $sDetail
        ConsoleWrite("[FAIL] " & $sName & " :: " & $sDetail & @CRLF)
        FileWrite($g_Log, "[FAIL] " & $sName & " :: " & $sDetail & @CRLF)
    EndIf
EndFunc

Func Eq($a, $b, $sName)
    Check($sName, $a = $b, "expected=" & $b & " actual=" & $a)
EndFunc

; ----------------------------- Deterministic RNG -----------------------------
; Park-Miller. Product stays below 2^53, so AutoIt's numeric representation
; remains exact for this generator.
Func Rnd32()
    $g_Seed = Mod($g_Seed * 16807, 2147483647)
    If $g_Seed <= 0 Then $g_Seed = 1
    Return $g_Seed
EndFunc

Func RndInt($lo, $hi)
    Return $lo + Mod(Rnd32(), $hi - $lo + 1)
EndFunc

; ----------------------------- State helpers ---------------------------------
Func HashPair()
    Return ChessCore_GetPositionHashHi() & ":" & ChessCore_GetPositionHashLo()
EndFunc

Func StateSig()
    Return ChessCore_GetFEN() & " |H=" & HashPair() & " |HC=" & ChessCore_GetMoveHistoryCount()
EndFunc

Func IsValidNow()
    Return ChessCore_ValidateCurrentPosition() = 1
EndFunc

Func HasUCI(Const ByRef $aMoves, $sUCI)
    For $i = 0 To UBound($aMoves) - 1
        If StringLower($aMoves[$i]) = StringLower($sUCI) Then Return True
    Next
    Return False
EndFunc

Func NoDuplicates(Const ByRef $aMoves)
    For $i = 0 To UBound($aMoves) - 1
        For $j = $i + 1 To UBound($aMoves) - 1
            If $aMoves[$i] = $aMoves[$j] Then Return False
        Next
    Next
    Return True
EndFunc

Func CountMoves(Const ByRef $aMoves)
    Return ChessCore_GetMoveCount($aMoves)
EndFunc

Func CheckMutationPreserved($sBefore, $sName)
    Local $after = StateSig()
    Check($sName, $after = $sBefore, "before=" & $sBefore & " after=" & $after)
EndFunc

Func CheckHashRebuildInPlace($sName)
    ; Critical: unlike SetFEN, this does NOT clear the trial MoveState stack.
    Local $h1 = HashPair()
    _Core_RebuildPositionHash()
    Local $h2 = HashPair()
    Local $ok = ($h1 = $h2)
    Check($sName, $ok, "before=" & $h1 & " rebuilt=" & $h2)
    Return $ok
EndFunc

; ----------------------------- 1. Boot / baseline -----------------------------
Say(@CRLF & "============================================================")
Say(" AUTOIT CHESSCORE — THE LAST JUDGMENT / ADVERSARIAL FORENSIC TEST SUITE")
Say("============================================================")
Say("Seed=" & $g_Seed)
Say("Core include: AutoIt_ChessCore.au3")

Check("Core_Init", ChessCore_Init() = 1, "err=" & @error)
Eq(ChessCore_GetFEN(), "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "Canonical start FEN")
Check("Start board invariant", IsValidNow(), "err=" & @error)
Check("Start legal moves unique", NoDuplicates(ChessCore_GenerateLegalMoves()), "duplicate root move")
Eq(CountMoves(ChessCore_GenerateLegalMoves()), 20, "Start legal move count")

; ----------------------------- 2. Perft monuments ----------------------------
Say(@CRLF & "--- PERFT MONUMENTS ---")

If $RUN_START_D5 Then
    ChessCore_SetFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    Local $t = TimerInit()
    Local $d5 = ChessCore_Perft(5)
    Local $ms = TimerDiff($t)
    Eq($d5, 4865609, "Start Perft(5)")
    Say("Start Perft(5) elapsed=" & Round($ms, 1) & " ms")
EndIf

If $RUN_KIWIPETE_D4 Then
    Local $K = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
    ChessCore_SetFEN($K)
    Eq(ChessCore_Perft(1), 48, "Kiwipete Perft(1)")
    Eq(ChessCore_Perft(2), 2039, "Kiwipete Perft(2)")
    Eq(ChessCore_Perft(3), 97862, "Kiwipete Perft(3)")
    Local $t2 = TimerInit()
    Local $kd4 = ChessCore_Perft(4)
    Local $kms = TimerDiff($t2)
    Eq($kd4, 4085603, "Kiwipete Perft(4)")
    Say("Kiwipete Perft(4) elapsed=" & Round($kms, 1) & " ms")
EndIf

If $RUN_POSITION3_D5 Then
    Local $P3 = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"
    ChessCore_SetFEN($P3)
    Eq(ChessCore_Perft(1), 14, "Position-3 Perft(1)")
    Eq(ChessCore_Perft(2), 191, "Position-3 Perft(2)")
    Eq(ChessCore_Perft(3), 2812, "Position-3 Perft(3)")
    Eq(ChessCore_Perft(4), 43238, "Position-3 Perft(4)")
    Local $t3 = TimerInit()
    Local $p3d5 = ChessCore_Perft(5)
    Local $p3ms = TimerDiff($t3)
    Eq($p3d5, 674624, "Position-3 Perft(5)")
    Say("Position-3 Perft(5) elapsed=" & Round($p3ms, 1) & " ms")
EndIf

; ----------------------------- 3. Canonical Kiwipete root ---------------------
Say(@CRLF & "--- ROOT FORENSICS ---")
Local $K2 = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
ChessCore_SetFEN($K2)
Local $rootState = StateSig()
Local $rootMoves = ChessCore_GenerateLegalMoves()
Check("Kiwipete root = 48", CountMoves($rootMoves) = 48, "actual=" & CountMoves($rootMoves))
Check("Kiwipete root unique", NoDuplicates($rootMoves), "duplicate legal UCI")
CheckMutationPreserved($rootState, "Kiwipete MoveGen nonmutation")
CheckHashRebuildInPlace("Kiwipete hash rebuild agreement")

; Every legal root move must survive Push/Pop without altering anything.
Local $rootUCI = ChessCore_GenerateLegalMoves()
For $i = 0 To UBound($rootUCI) - 1
    Local $before = StateSig()
    Local $mv = $rootUCI[$i]
    Local $okPush = ChessCore_PushMove($mv)
    SilentCheck("Kiwipete Push/Pop " & $mv & " push", $okPush = 1, "err=" & @error)
    SilentCheck("Kiwipete Push/Pop " & $mv & " valid-after", IsValidNow(), "err=" & @error)
    If $okPush Then ChessCore_PopMove()
    SilentCheck("Kiwipete Push/Pop " & $mv & " restore", StateSig() = $before, "state changed")
Next

; ----------------------------- 4. Packed move bijection -----------------------
Say(@CRLF & "--- PACKED-MOVE BIJECTION ---")
For $i = 1 To $PACKED_RANDOM_CASES
    Local $from = RndInt(0, 63)
    Local $to = RndInt(0, 63)
    Local $promo = RndInt(0, 7)
    Local $flags = RndInt(0, 31)
    Local $packed = _Core_EncodeMove($from, $to, $promo, $flags)
    Local $okRound = (_Core_MoveFrom($packed) = $from And _Core_MoveTo($packed) = $to And _Core_MovePromo($packed) = $promo And _Core_MoveFlags($packed) = $flags)
    SilentCheck("Packed bijection #" & $i, $okRound, "packed=" & $packed)
Next
Say("Packed cases=" & $PACKED_RANDOM_CASES)

; ----------------------------- 5. Parser transaction gauntlet -----------------
Say(@CRLF & "--- FEN TRANSACTION GAUNTLET ---")
Local $validFEN[9] = [ _
    "4k3/8/8/8/8/8/8/4K3 w - - 0 1", _
    "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", _
    "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", _
    "7k/8/8/8/8/8/8/K7 w - - 0 1", _
    "4k3/8/8/8/8/8/4P3/4K3 b - - 99 999999", _
    "4k3/8/8/8/8/8/8/4K3 b - - 0 1", _
    "8/8/8/8/8/8/8/R3K2k w - - 0 1", _
    "4k3/8/8/8/3Pp3/8/8/4K3 b - d3 0 1", _
    "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 17 42" _
]

For $i = 0 To UBound($validFEN) - 1
    Check("Valid FEN #" & ($i + 1), ChessCore_ValidateFEN($validFEN[$i]) = 1, "err=" & @error & " fen=" & $validFEN[$i])
Next

Local $invalidFEN[16] = [ _
    "8/8/8/8/8/8/8/8 w - - 0 1", _
    "4k3/8/8/8/8/8/8/4K3 x - - 0 1", _
    "4k3/8/8/8/8/8/8/4K3 w KK - 0 1", _
    "4k3/8/8/8/8/8/8/4K3 w KQkqz - 0 1", _
    "4k3/8/8/8/8/8/8/4K3 w - z9 0 1", _
    "4k3/8/8/8/8/8/8/4K3 w - - -1 1", _
    "4k3/8/8/8/8/8/8/4K3 w - - 0 0", _
    "4k3/8/8/8/8/8/8/4K3 w K - 0 1", _
    "4k3/8/8/8/8/8/8/4K3 w - e1 0 1", _
    "4k3/8/8/8/8/8/8/4K3 w - - 0", _
    "4k3/8/8/8/8/8/8/4K3 w - - 0 1 extra", _
    "4k3/8/8/8/8/8/8/4K3 w - - 0 1/", _
    "4k3/8/8/8/8/8/8/4K3 w Kkqq - 0 1", _
    "4k3/8/8/8/8/8/8/4K3 w - a4 0 1", _
    "r3k2r/8/8/8/8/8/8/R3K3 w KQkq - 0 1", _
    "3k4/3K4/8/8/8/8/8/8 w - - 0 1" _
]

For $i = 0 To UBound($invalidFEN) - 1
    Check("Invalid FEN rejected #" & ($i + 1), ChessCore_ValidateFEN($invalidFEN[$i]) = 0, "accepted err=" & @error & " fen=" & $invalidFEN[$i])
Next

; Bad SetFEN must not mutate a live position.
ChessCore_SetFEN($K2)
Local $beforeBadFEN = StateSig()
Local $badResult = ChessCore_SetFEN($invalidFEN[3])
Check("Rejected SetFEN returns failure", $badResult = 0, "result=" & $badResult & " err=" & @error)
Check("Rejected SetFEN is transactional", StateSig() = $beforeBadFEN, "state mutated")

; ----------------------------- 6. Clock-blind position identity --------------
Say(@CRLF & "--- POSITION-IDENTITY LAWS ---")
Local $clockA = "4k3/8/8/8/8/8/8/4K3 w - - 0 1"
Local $clockB = "4k3/8/8/8/8/8/8/4K3 w - - 73 999"
ChessCore_SetFEN($clockA)
Local $hashA = HashPair()
ChessCore_SetFEN($clockB)
Local $hashB = HashPair()
Check("Half/fullmove are excluded from position identity", $hashA = $hashB, "A=" & $hashA & " B=" & $hashB)

Local $epLegal = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1"
Local $epNone = "4k3/8/8/3pP3/8/8/8/4K3 w - - 0 1"
ChessCore_SetFEN($epLegal)
Local $epHash1 = HashPair()
ChessCore_SetFEN($epNone)
Local $epHash2 = HashPair()
Check("Legal EP changes position identity", $epHash1 <> $epHash2, "EP hash was ignored")

Local $epPinned = "4r1k1/8/8/3pP3/8/8/8/4K3 w - d6 0 1"
Local $epPinnedNone = "4r1k1/8/8/3pP3/8/8/8/4K3 w - - 0 1"
ChessCore_SetFEN($epPinned)
Local $pinMoves = ChessCore_GenerateLegalMoves()
Local $pinHash = HashPair()
ChessCore_SetFEN($epPinnedNone)
Local $pinNoneMoves = ChessCore_GenerateLegalMoves()
Local $pinNoneHash = HashPair()
Check("Pinned EP is absent from legal moves", Not HasUCI($pinMoves, "e5d6"), "e5d6 unexpectedly legal")
Check("Pinned EP normalizes away from hash", $pinHash = $pinNoneHash, "pinned=" & $pinHash & " none=" & $pinNoneHash)

; ----------------------------- 7. Special-move courtroom ----------------------
Say(@CRLF & "--- SPECIAL-MOVE COURTROOM ---")

; Castling
Local $castleFEN = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
ChessCore_SetFEN($castleFEN)
Local $castleMoves = ChessCore_GenerateLegalMoves()
Check("White O-O present", HasUCI($castleMoves, "e1g1"), "missing e1g1")
Check("White O-O-O present", HasUCI($castleMoves, "e1c1"), "missing e1c1")
Local $castleBase = StateSig()
Check("Castle push accepted", ChessCore_PushMove("e1g1") = 1, "err=" & @error)
Check("Castle rook lands f1", ChessCore_GetPiece(5) = $PIECE_WHITE_ROOK, "piece=" & ChessCore_GetPiece(5))
Check("Castle king lands g1", ChessCore_GetPiece(6) = $PIECE_WHITE_KING, "piece=" & ChessCore_GetPiece(6))
Check("Castle loses white rights", ChessCore_GetCastlingRights() = "kq", "rights=" & ChessCore_GetCastlingRights())
Check("Castle pop restores exact state", ChessCore_PopMove() = 1 And StateSig() = $castleBase, "state changed")

; Promotion, including capture-promotion.
Local $promoFEN = "1r2k3/P7/8/8/8/8/8/4K3 w - - 0 1"
ChessCore_SetFEN($promoFEN)
Local $promoMoves = ChessCore_GenerateLegalMoves()
Local $promoExpected[8] = ["a7a8q","a7a8r","a7a8b","a7a8n","a7b8q","a7b8r","a7b8b","a7b8n"]
For $i = 0 To 7
    Check("Promotion move present " & $promoExpected[$i], HasUCI($promoMoves, $promoExpected[$i]), "missing")
Next
Local $promoBase = StateSig()
For $i = 0 To 7
    Local $u = $promoExpected[$i]
    If ChessCore_PushMove($u) Then
        SilentCheck("Promotion " & $u & " valid-after", IsValidNow(), "invalid position")
        SilentCheck("Promotion " & $u & " pop", ChessCore_PopMove() = 1, "pop err=" & @error)
        SilentCheck("Promotion " & $u & " exact restore", StateSig() = $promoBase, "state changed")
    Else
        Check("Promotion " & $u & " push", False, "err=" & @error)
    EndIf
Next

; EP capture and its exact rollback.
ChessCore_SetFEN($epLegal)
Local $epBase = StateSig()
Local $epMoves = ChessCore_GenerateLegalMoves()
Check("Legal EP move present", HasUCI($epMoves, "e5d6"), "missing e5d6")
Check("EP push", ChessCore_PushMove("e5d6") = 1, "err=" & @error)
Check("EP captured pawn removed", ChessCore_GetPiece(35) = $PIECE_EMPTY, "d5 not empty")
Check("EP pawn lands d6", ChessCore_GetPiece(43) = $PIECE_WHITE_PAWN, "d6 piece=" & ChessCore_GetPiece(43))
Check("EP pop exact restore", ChessCore_PopMove() = 1 And StateSig() = $epBase, "state changed")

; Check-evasion sanity.
Local $checkFEN = "4r1k1/8/8/8/8/8/8/4K3 w - - 0 1"
ChessCore_SetFEN($checkFEN)
Check("Check detected", ChessCore_IsCheck(), "side to move should be checked")
Local $evasions = ChessCore_GenerateLegalMoves()
Check("Checked king has only legal evasions", CountMoves($evasions) > 0 And CountMoves($evasions) < 8, "count=" & CountMoves($evasions))

; ----------------------------- 8. Trial Make/Unmake courtroom -----------------
Say(@CRLF & "--- MAKE/UNMAKE COURTROOM ---")
ChessCore_SetFEN($K2)
Local $trialBase = StateSig()
Local $packedRoot = Core_GenerateLegalMoves()
Local $packedN = UBound($packedRoot)
For $i = 0 To $packedN - 1
    Core_MakeMove($packedRoot[$i])
    SilentCheck("Trial Make legal #" & $i, IsValidNow(), "move=" & Core_MoveToUCI($packedRoot[$i]))
    SilentCheck("Trial hash rebuild #" & $i, CheckHashRebuildInPlace("__internal_hash__"), "hash")
    Core_UnmakeMove()
    SilentCheck("Trial Unmake exact #" & $i, StateSig() = $trialBase, "move=" & Core_MoveToUCI($packedRoot[$i]))
Next

; ----------------------------- 9. Dynamic trial-stack avalanche --------------
Say(@CRLF & "--- MOVE-STACK AVALANCHE ---")
ChessCore_SetFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
Local $avalancheBase = StateSig()
Local $avalancheCount = 0
For $ply = 1 To $TRIAL_AVALANCHE_DEPTH
    Local $am = Core_GenerateLegalMoves()
    Local $an = UBound($am)
    If $an = 0 Then ExitLoop
    Local $pick = $am[RndInt(0, $an - 1)]
    Core_MakeMove($pick)
    $avalancheCount += 1
Next
Say("Trial stack reached depth=" & $avalancheCount)
For $i = 1 To $avalancheCount
    If Not Core_UnmakeMove() Then
        Check("Trial avalanche unmake #" & $i, False, "err=" & @error)
        ExitLoop
    EndIf
Next
Check("Trial avalanche exact restoration", StateSig() = $avalancheBase, "state changed after " & $avalancheCount & " Make/Unmake levels")

; ----------------------------- 10. Public history avalanche -------------------
Say(@CRLF & "--- COMMITTED-HISTORY AVALANCHE ---")
ChessCore_SetFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
Local $historyBase = StateSig()
Local $historyPlies = 0
For $ply = 1 To $HISTORY_AVALANCHE_PLIES
    Local $hm = ChessCore_GenerateLegalMoves()
    Local $hn = UBound($hm)
    If $hn = 0 Then ExitLoop
    Local $hchoice = $hm[RndInt(0, $hn - 1)]
    If Not ChessCore_PushMove($hchoice) Then
        Check("History avalanche push #" & $ply, False, "move=" & $hchoice & " err=" & @error)
        ExitLoop
    EndIf
    $historyPlies += 1
Next
Say("Committed history reached plies=" & $historyPlies & " count=" & ChessCore_GetMoveHistoryCount())
Check("History count equals pushes", ChessCore_GetMoveHistoryCount() = $historyPlies, "count=" & ChessCore_GetMoveHistoryCount())
For $i = 1 To $historyPlies
    If Not ChessCore_PopMove() Then
        Check("History avalanche pop #" & $i, False, "err=" & @error)
        ExitLoop
    EndIf
Next
Check("History avalanche exact restoration", StateSig() = $historyBase, "state changed")
Check("History root count restored", ChessCore_GetMoveHistoryCount() = 0, "count=" & ChessCore_GetMoveHistoryCount())

; ----------------------------- 11. History/trial isolation --------------------
Say(@CRLF & "--- HISTORY / TRIAL ISOLATION ---")
ChessCore_SetFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
Check("Push baseline", ChessCore_PushMove("e2e4") = 1, "err=" & @error)
Local $isoBefore = StateSig()
Local $isoCount = ChessCore_GetMoveHistoryCount()
Local $isoPerft = ChessCore_Perft(3)
Local $isoAfterPerft = StateSig()
Check("Perft does not alter committed history", $isoAfterPerft = $isoBefore And ChessCore_GetMoveHistoryCount() = $isoCount, "before=" & $isoBefore & " after=" & $isoAfterPerft)
Local $isoMoves = ChessCore_GenerateLegalMoves()
Check("MoveGen does not alter committed history", StateSig() = $isoBefore And ChessCore_GetMoveHistoryCount() = $isoCount, "state changed")
Check("Isolation cleanup pop", ChessCore_PopMove() = 1, "err=" & @error)
Check("Isolation cleanup root", ChessCore_GetMoveHistoryCount() = 0, "count=" & ChessCore_GetMoveHistoryCount())

; ----------------------------- 12. Illegal-input immutability -----------------
Say(@CRLF & "--- ILLEGAL-INPUT IMMUTABILITY ---")
ChessCore_SetFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
Local $rejects[14] = ["e2e5","e2e4q","a1a3","e1e2","e7e5","zzzz","a9a1","e2e4n","e2e4x","e2e4qq","e1g1","b1b3","a1a8","h7h5q"]
For $i = 0 To UBound($rejects) - 1
    Local $rb = StateSig()
    Local $r = ChessCore_PushMove($rejects[$i])
    SilentCheck("Rejected move result " & $rejects[$i], $r = 0, "accepted err=" & @error)
    SilentCheck("Rejected move state " & $rejects[$i], StateSig() = $rb, "state mutated")
Next

Local $rb2 = StateSig()
Check("Invalid side setter", ChessCore_SetSideToMove("x") = 0, "err=" & @error)
Check("Invalid side setter transactional", StateSig() = $rb2, "mutated")
Check("Invalid castling setter", ChessCore_SetCastlingRights("KZZ") = 0, "err=" & @error)
Check("Invalid castling setter transactional", StateSig() = $rb2, "mutated")
Check("Invalid EP setter low", ChessCore_SetEnPassantSquare(-2) = 0, "err=" & @error)
Check("Invalid EP setter low transactional", StateSig() = $rb2, "mutated")
Check("Invalid EP setter high", ChessCore_SetEnPassantSquare(64) = 0, "err=" & @error)
Check("Invalid EP setter high transactional", StateSig() = $rb2, "mutated")

; ----------------------------- 13. Repetition mathematics ---------------------
Say(@CRLF & "--- REPETITION MATHEMATICS ---")
ChessCore_SetFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
Local $repSeq[8] = ["g1f3","g8f6","f3g1","f6g8","g1f3","g8f6","f3g1","f6g8"]
For $i = 0 To 7
    Check("Repetition sequence " & ($i + 1), ChessCore_PushMove($repSeq[$i]) = 1, "move=" & $repSeq[$i] & " err=" & @error)
Next
Check("Threefold repetition reached", ChessCore_CountRepetitions() >= 3, "count=" & ChessCore_CountRepetitions())
Check("Repetition position returns to root", StringRegExp(ChessCore_GetFEN(), "^rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - [0-9]+ [0-9]+$"), "fen=" & ChessCore_GetFEN())
Check("Repetition reports draw", ChessCore_IsDraw(), "status=" & ChessCore_GetGameStatus())
For $i = 1 To 8
    If Not ChessCore_PopMove() Then ExitLoop
Next

; ----------------------------- 14. Random-game endurance ----------------------
Say(@CRLF & "--- 50-GAME DETERMINISTIC ENDURANCE / SENTINEL-SAFE ---")
Local $randomFailures = 0
For $game = 1 To $RANDOM_GAMES
    ChessCore_SetFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    Local $gameBase = StateSig()
    Local $plies = 0
    For $ply = 1 To $RANDOM_PLIES_PER_GAME
        Local $moves = ChessCore_GenerateLegalMoves()
        Local $n = ChessCore_GetMoveCount($moves)
        If $n = 0 Then ExitLoop
        Local $choice = $moves[RndInt(0, $n - 1)]
        If $choice = "" Then
            $randomFailures += 1
            SilentCheck("Random g" & $game & " p" & $ply & " sentinel leak", False, "UBound=" & UBound($moves) & " Count=" & $n & " move=<empty>")
            ExitLoop
        EndIf
        Local $beforeMove = StateSig()
        Local $ok = ChessCore_PushMove($choice)
        If Not $ok Then
            $randomFailures += 1
            SilentCheck("Random g" & $game & " p" & $ply & " push", False, "move=" & $choice & " err=" & @error)
            ExitLoop
        EndIf
        $plies += 1

        If Mod($ply, $CHECK_EVERY_RANDOM_PLY) = 0 Then
            SilentCheck("Random g" & $game & " p" & $ply & " invariant", IsValidNow(), "fen=" & ChessCore_GetFEN())
        EndIf

        If Mod($ply, $HASH_REBUILD_EVERY_RANDOM_PLY) = 0 Then
            Local $rh = HashPair()
            _Core_RebuildPositionHash()
            SilentCheck("Random g" & $game & " p" & $ply & " hash rebuild", HashPair() = $rh, "old=" & $rh & " new=" & HashPair())
        EndIf

        If Mod($ply, 73) = 0 Then
            Local $probe = ChessCore_GenerateLegalMoves()
            SilentCheck("Random g" & $game & " p" & $ply & " move uniqueness", NoDuplicates($probe), "duplicate move")
        EndIf
    Next

    ; The current state must always remain a valid chess position.
    SilentCheck("Random game " & $game & " final invariant", IsValidNow(), "plies=" & $plies)

    If Mod($game, 5) = 0 Or $game = $RANDOM_GAMES Then
        Say("Random games completed: " & $game & "/" & $RANDOM_GAMES)
    EndIf

    ; Restore a canonical state for the next game, proving reset works after a
    ; possibly very deep stack/history path.
    ChessCore_SetFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    SilentCheck("Random game " & $game & " reset", StateSig() = $gameBase, "reset mismatch")
Next

; ----------------------------- 15. Hash uniqueness sample ---------------------
Say(@CRLF & "--- HASH COLLISION SENTINEL ---")
; This does not prove collision freedom. It detects accidental identity drift
; inside a deterministic sample: equal hashes must correspond to equal position
; identity (ignoring move clocks).
Local $seenHash[1]
Local $seenKey[1]
Local $seenN = 0
ChessCore_SetFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
For $s = 1 To $HASH_RANDOM_SAMPLES
    Local $hmoves = ChessCore_GenerateLegalMoves()
    Local $hn = ChessCore_GetMoveCount($hmoves)
    If $hn = 0 Then ChessCore_SetFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    $hmoves = ChessCore_GenerateLegalMoves()
    $hn = UBound($hmoves)
    If $hn = 0 Then ExitLoop
    ChessCore_PushMove($hmoves[RndInt(0, $hn - 1)])
    Local $hf = ChessCore_GetFEN()
    Local $hh = HashPair()
    Local $keyParts = StringSplit($hf, " ", 2)
    Local $identityKey = $keyParts[0] & " " & $keyParts[1] & " " & $keyParts[2] & " " & $keyParts[3]

    Local $collisionOK = True
    For $z = 0 To $seenN - 1
        If $seenHash[$z] = $hh And $seenKey[$z] <> $identityKey Then
            $collisionOK = False
            ExitLoop
        EndIf
    Next
    SilentCheck("Hash collision sentinel sample #" & $s, $collisionOK, "hash=" & $hh & " key=" & $identityKey)

    If $seenN = UBound($seenHash) Then
        ReDim $seenHash[$seenN + 256]
        ReDim $seenKey[$seenN + 256]
    EndIf
    $seenHash[$seenN] = $hh
    $seenKey[$seenN] = $identityKey
    $seenN += 1

    If Mod($s, 50) = 0 Then
        ; Deliberately commit a reset so this sampling remains bounded and clean.
        ChessCore_SetFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    EndIf
Next

; ----------------------------- 16. Final invariants ---------------------------
Say(@CRLF & "--- FINAL INVARIANTS ---")
ChessCore_SetFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
Check("Final canonical FEN", ChessCore_GetFEN() = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", ChessCore_GetFEN())
Check("Final board invariant", IsValidNow(), "err=" & @error)
Check("Final history root", ChessCore_GetMoveHistoryCount() = 0, "count=" & ChessCore_GetMoveHistoryCount())
Check("Final root move count", CountMoves(ChessCore_GenerateLegalMoves()) = 20, "count=" & CountMoves(ChessCore_GenerateLegalMoves()))
CheckHashRebuildInPlace("Final hash rebuild agreement")
Check("Final exact canonical state", ChessCore_GetFEN() = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", "state drift")

; ----------------------------- Verdict ----------------------------------------
Say(@CRLF & "============================================================")
Say(" THE LAST JUDGMENT — VERDICT")
Say("============================================================")
Say("TOTAL=" & $g_Total)
Say("PASS=" & $g_Pass)
Say("FAIL=" & $g_Fail)
Say("SEED_FINAL=" & $g_Seed)
If $g_FirstFailure = "" Then
    Say("VERDICT=OMEGA PASS — NO FAILURE FOUND")
    Say("The Phase-10 core survived this torture suite without a detected invariant breach.")
Else
    Say("VERDICT=FAIL — FIRST FAILURE:")
    Say($g_FirstFailure)
    Say("Failure log: " & $g_Log)
EndIf
Say("============================================================")

Exit
