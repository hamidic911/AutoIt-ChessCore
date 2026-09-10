#cs ----------------------------------------------------------------------------
    MYBOT RUN CHESS - Chess Core
    Phase 10: Unified Native Chess Core

    Native AutoIt 3.3.18.0

    Design goals
      - One self-contained chess core; no Phase-9 dependency.
      - Preserve the established ChessCore_* public API and FEN/UCI contracts.
      - Keep the reliable Phase-9 rule semantics while replacing hot-path costs.
      - Packed internal moves instead of UCI strings.
      - Incremental make/unmake with a compact undo stack.
      - Logical 64-bit Zobrist identity represented as Hi32 + Lo32.
      - Repetition history is committed-game history only; trial moves never touch it.
      - Perft and legal move generation use the same make/check/unmake path.
      - Mailbox[64] board retained intentionally for clarity and AutoIt performance.

    This file is written as one coherent implementation. There is no runtime
    include or dependency on an earlier ChessCore generation.
#ce ----------------------------------------------------------------------------

#include-once

; ============================== Constants ======================================
Global Const $BOARD_SIZE = 64

Global Const $PIECE_EMPTY        = 0
Global Const $PIECE_WHITE_PAWN   = 1
Global Const $PIECE_WHITE_KNIGHT = 2
Global Const $PIECE_WHITE_BISHOP = 3
Global Const $PIECE_WHITE_ROOK   = 4
Global Const $PIECE_WHITE_QUEEN  = 5
Global Const $PIECE_WHITE_KING   = 6
Global Const $PIECE_BLACK_PAWN   = 7
Global Const $PIECE_BLACK_KNIGHT = 8
Global Const $PIECE_BLACK_BISHOP = 9
Global Const $PIECE_BLACK_ROOK   = 10
Global Const $PIECE_BLACK_QUEEN  = 11
Global Const $PIECE_BLACK_KING   = 12

Global Const $CASTLE_WK = 1
Global Const $CASTLE_WQ = 2
Global Const $CASTLE_BK = 4
Global Const $CASTLE_BQ = 8

Global Const $MOVE_FLAG_NORMAL      = 0
Global Const $MOVE_FLAG_CAPTURE     = 1
Global Const $MOVE_FLAG_DOUBLE_PAWN = 2
Global Const $MOVE_FLAG_CASTLING    = 4
Global Const $MOVE_FLAG_EN_PASSANT  = 8
Global Const $MOVE_FLAG_PROMOTION   = 16

; ============================== Position State ================================
Global $g_Board[$BOARD_SIZE]
Global $g_SideToMove = 'w'
Global $g_CastlingRights = 15
Global $g_EnPassant = -1
Global $g_HalfmoveClock = 0
Global $g_FullmoveNumber = 1
Global $g_WhiteKingSquare = -1
Global $g_BlackKingSquare = -1

; ============================== Zobrist ========================================
; AutoIt bitwise primitives are 32-bit. We therefore represent every
; Zobrist value as an explicit high/low 32-bit pair rather than pretending a
; BitXOR expression is a native 64-bit operation.
Global $g_ZobristPieceHi[13][64]
Global $g_ZobristPieceLo[13][64]
Global $g_ZobristSideHi = 0
Global $g_ZobristSideLo = 0
Global $g_ZobristCastleHi[16]
Global $g_ZobristCastleLo[16]
Global $g_ZobristEPFileHi[8]
Global $g_ZobristEPFileLo[8]
Global $g_ZobristHashHi = 0
Global $g_ZobristHashLo = 0
Global $g_ZobristEPFileActive = -1
Global $g_ZobristReady = False

; ============================== Move / Undo Stack ==============================
; A Move occupies 20 bits:
;   0..5   from square
;   6..11  to square
;   12..14 promotion piece type (white piece constants used as type ids)
;   15..19 move flags
Global $g_MoveStackCapacity = 256
Global $g_MoveStackMove[256]
Global $g_MoveStackCaptured[256]
Global $g_MoveStackCastling[256]
Global $g_MoveStackEP[256]
Global $g_MoveStackHalfmove[256]
Global $g_MoveStackFullmove[256]
Global $g_MoveStackHashHi[256]
Global $g_MoveStackHashLo[256]
Global $g_MoveStackEPHashFile[256]
Global $g_MoveStackWhiteKing[256]
Global $g_MoveStackBlackKing[256]
Global $g_MoveStackCount = 0

; Committed game history. Trial Move/Unmake never touches this.
Global $g_GameHistoryCapacity = 256
Global $g_GameHistoryMove[256]
Global $g_GameHistoryHashHi[256]
Global $g_GameHistoryHashLo[256]
Global $g_GameHistoryCount = 0

; ============================== Move Encoding ==================================
Func _Core_EncodeMove($iFrom, $iTo, $iPromo = $PIECE_EMPTY, $iFlags = $MOVE_FLAG_NORMAL)
    Return BitOR(BitAND($iFrom, 0x3F), BitShift(BitAND($iTo, 0x3F), -6), BitShift(BitAND($iPromo, 0x07), -12), BitShift(BitAND($iFlags, 0x1F), -15))
EndFunc

Func _Core_MoveFrom($iMove)
    Return BitAND($iMove, 0x3F)
EndFunc

Func _Core_MoveTo($iMove)
    Return BitAND(BitShift($iMove, 6), 0x3F)
EndFunc

Func _Core_MovePromo($iMove)
    Return BitAND(BitShift($iMove, 12), 0x07)
EndFunc

Func _Core_MoveFlags($iMove)
    Return BitAND(BitShift($iMove, 15), 0x1F)
EndFunc

Func _Core_MoveIsCapture($iMove)
    Return BitAND(_Core_MoveFlags($iMove), $MOVE_FLAG_CAPTURE) <> 0
EndFunc

; ============================== Coordinate Helpers ============================
Func ChessCore_FileRankToIndex($iFile, $iRank)
    If $iFile < 0 Or $iFile > 7 Or $iRank < 0 Or $iRank > 7 Then Return SetError(1, 0, -1)
    Return $iRank * 8 + $iFile
EndFunc

Func ChessCore_IndexToFileRank($iIndex, ByRef $iFile, ByRef $iRank)
    If $iIndex < 0 Or $iIndex > 63 Then
        $iFile = -1
        $iRank = -1
        Return SetError(1, 0, 0)
    EndIf
    $iFile = Mod($iIndex, 8)
    $iRank = Int($iIndex / 8)
    Return 1
EndFunc

Func ChessCore_SquareToIndex($sSquare)
    If StringLen($sSquare) <> 2 Then Return SetError(1, 0, -1)
    Local $sFile = StringLower(StringLeft($sSquare, 1))
    Local $sRank = StringRight($sSquare, 1)
    If StringInStr('abcdefgh', $sFile) = 0 Then Return SetError(2, 0, -1)
    If Not StringRegExp($sRank, '^[1-8]$') Then Return SetError(3, 0, -1)
    Return (Asc($sRank) - Asc('1')) * 8 + (Asc($sFile) - Asc('a'))
EndFunc

Func ChessCore_IndexToSquare($iIndex)
    Local $iFile, $iRank
    If Not ChessCore_IndexToFileRank($iIndex, $iFile, $iRank) Then Return SetError(1, 0, '')
    Return Chr(Asc('a') + $iFile) & Chr(Asc('1') + $iRank)
EndFunc

; ============================== Piece Helpers ==================================
Func _ChessCore_IsWhitePiece($iPiece)
    Return $iPiece >= $PIECE_WHITE_PAWN And $iPiece <= $PIECE_WHITE_KING
EndFunc

Func _ChessCore_IsBlackPiece($iPiece)
    Return $iPiece >= $PIECE_BLACK_PAWN And $iPiece <= $PIECE_BLACK_KING
EndFunc

Func _ChessCore_IsPawn($iPiece)
    Return $iPiece = $PIECE_WHITE_PAWN Or $iPiece = $PIECE_BLACK_PAWN
EndFunc

Func _ChessCore_IsKing($iPiece)
    Return $iPiece = $PIECE_WHITE_KING Or $iPiece = $PIECE_BLACK_KING
EndFunc

Func _ChessCore_IsValidPiece($iPiece)
    Return $iPiece >= $PIECE_EMPTY And $iPiece <= $PIECE_BLACK_KING
EndFunc

Func _ChessCore_PieceToChar($iPiece)
    Switch $iPiece
        Case $PIECE_WHITE_PAWN
            Return 'P'
        Case $PIECE_WHITE_KNIGHT
            Return 'N'
        Case $PIECE_WHITE_BISHOP
            Return 'B'
        Case $PIECE_WHITE_ROOK
            Return 'R'
        Case $PIECE_WHITE_QUEEN
            Return 'Q'
        Case $PIECE_WHITE_KING
            Return 'K'
        Case $PIECE_BLACK_PAWN
            Return 'p'
        Case $PIECE_BLACK_KNIGHT
            Return 'n'
        Case $PIECE_BLACK_BISHOP
            Return 'b'
        Case $PIECE_BLACK_ROOK
            Return 'r'
        Case $PIECE_BLACK_QUEEN
            Return 'q'
        Case $PIECE_BLACK_KING
            Return 'k'
    EndSwitch
    Return SetError(1, 0, '')
EndFunc

Func _ChessCore_CharToPiece($sChar)
    ; IMPORTANT: AutoIt Switch string matching is case-insensitive. FEN piece
    ; letters are case-sensitive (upper=White, lower=Black), so use ==.
    If $sChar == 'P' Then Return $PIECE_WHITE_PAWN
    If $sChar == 'N' Then Return $PIECE_WHITE_KNIGHT
    If $sChar == 'B' Then Return $PIECE_WHITE_BISHOP
    If $sChar == 'R' Then Return $PIECE_WHITE_ROOK
    If $sChar == 'Q' Then Return $PIECE_WHITE_QUEEN
    If $sChar == 'K' Then Return $PIECE_WHITE_KING
    If $sChar == 'p' Then Return $PIECE_BLACK_PAWN
    If $sChar == 'n' Then Return $PIECE_BLACK_KNIGHT
    If $sChar == 'b' Then Return $PIECE_BLACK_BISHOP
    If $sChar == 'r' Then Return $PIECE_BLACK_ROOK
    If $sChar == 'q' Then Return $PIECE_BLACK_QUEEN
    If $sChar == 'k' Then Return $PIECE_BLACK_KING
    Return SetError(1, 0, -1)
EndFunc

; ============================== Board Helpers =================================
Func _ChessCore_RebuildKingCache()
    $g_WhiteKingSquare = -1
    $g_BlackKingSquare = -1
    For $i = 0 To 63
        Switch $g_Board[$i]
            Case $PIECE_WHITE_KING
                $g_WhiteKingSquare = $i
            Case $PIECE_BLACK_KING
                $g_BlackKingSquare = $i
        EndSwitch
    Next
EndFunc

Func ChessCore_GetPiece($iSquare)
    If $iSquare < 0 Or $iSquare > 63 Then Return SetError(1, 0, $PIECE_EMPTY)
    Return $g_Board[$iSquare]
EndFunc

Func _ChessCore_ValidateBoardShape(Const ByRef $aBoard64)
    If UBound($aBoard64) <> 64 Then Return SetError(1, 0, False)

    Local $wk = 0, $bk = 0, $wp = 0, $bp = 0, $whitePieces = 0, $blackPieces = 0
    For $sq = 0 To 63
        Local $p = $aBoard64[$sq]
        If Not _ChessCore_IsValidPiece($p) Then Return SetError(2, 0, False)
        If $p = $PIECE_WHITE_KING Then $wk += 1
        If $p = $PIECE_BLACK_KING Then $bk += 1
        If $p = $PIECE_WHITE_PAWN Then $wp += 1
        If $p = $PIECE_BLACK_PAWN Then $bp += 1
        If _ChessCore_IsWhitePiece($p) Then $whitePieces += 1
        If _ChessCore_IsBlackPiece($p) Then $blackPieces += 1
        If ($p = $PIECE_WHITE_PAWN Or $p = $PIECE_BLACK_PAWN) Then
            Local $r = Int($sq / 8)
            If $r = 0 Or $r = 7 Then Return SetError(3, 0, False)
        EndIf
    Next

    If $wk <> 1 Or $bk <> 1 Then Return SetError(4, 0, False)
    If $wp > 8 Or $bp > 8 Then Return SetError(5, 0, False)
    If $whitePieces > 16 Or $blackPieces > 16 Then Return SetError(6, 0, False)
    Return 1
EndFunc

Func ChessCore_ValidateBoardIntegrity()
    Return _ChessCore_ValidateBoardShape($g_Board)
EndFunc

Func _ChessCore_ClearCommittedHistory()
    $g_GameHistoryCount = 0
EndFunc

Func _ChessCore_ClearMoveStack()
    $g_MoveStackCount = 0
EndFunc

Func ChessCore_SetPiece($iSquare, $iPiece)
    If $iSquare < 0 Or $iSquare > 63 Then Return SetError(1, 0, 0)
    If Not _ChessCore_IsValidPiece($iPiece) Then Return SetError(2, 0, 0)

    Local $oldPiece = $g_Board[$iSquare]
    Local $oldWK = $g_WhiteKingSquare
    Local $oldBK = $g_BlackKingSquare
    $g_Board[$iSquare] = $iPiece
    _ChessCore_RebuildKingCache()

    If Not _ChessCore_ValidateBoardShape($g_Board) Then
        Local $errShape = @error
        $g_Board[$iSquare] = $oldPiece
        $g_WhiteKingSquare = $oldWK
        $g_BlackKingSquare = $oldBK
        Return SetError($errShape, 0, 0)
    EndIf

    ; Preserve the current side/castling/EP context. A board edit is accepted
    ; only if that complete position remains valid.
    If Not ChessCore_ValidateCurrentPosition() Then
        Local $errState = @error
        $g_Board[$iSquare] = $oldPiece
        $g_WhiteKingSquare = $oldWK
        $g_BlackKingSquare = $oldBK
        Return SetError(20 + $errState, 0, 0)
    EndIf

    _ChessCore_ClearMoveStack()
    _ChessCore_ClearCommittedHistory()
    _Core_RebuildPositionHash()
    _Core_GameHistoryPushHash()
    Return 1
EndFunc

Func ChessCore_SetBoardSnapshot(Const ByRef $aBoard64)
    If UBound($aBoard64) <> 64 Then Return SetError(1, 0, 0)
    If Not _ChessCore_ValidateBoardShape($aBoard64) Then Return SetError(@error, 0, 0)

    Local $oldBoard[64]
    For $i = 0 To 63
        $oldBoard[$i] = $g_Board[$i]
    Next
    Local $oldWK = $g_WhiteKingSquare
    Local $oldBK = $g_BlackKingSquare

    For $i = 0 To 63
        $g_Board[$i] = $aBoard64[$i]
    Next
    _ChessCore_RebuildKingCache()

    If Not ChessCore_ValidateCurrentPosition() Then
        Local $errState = @error
        For $i = 0 To 63
            $g_Board[$i] = $oldBoard[$i]
        Next
        $g_WhiteKingSquare = $oldWK
        $g_BlackKingSquare = $oldBK
        Return SetError(20 + $errState, 0, 0)
    EndIf

    _ChessCore_ClearMoveStack()
    _ChessCore_ClearCommittedHistory()
    _Core_RebuildPositionHash()
    _Core_GameHistoryPushHash()
    Return 1
EndFunc

Func ChessCore_GetBoardSnapshot()
    Local $aBoard[64]
    For $i = 0 To 63
        $aBoard[$i] = $g_Board[$i]
    Next
    Return $aBoard
EndFunc

; ============================== Castling =======================================
Func ChessCore_GetCastlingRights()
    Local $s = ''
    If BitAND($g_CastlingRights, $CASTLE_WK) Then $s &= 'K'
    If BitAND($g_CastlingRights, $CASTLE_WQ) Then $s &= 'Q'
    If BitAND($g_CastlingRights, $CASTLE_BK) Then $s &= 'k'
    If BitAND($g_CastlingRights, $CASTLE_BQ) Then $s &= 'q'
    If $s = '' Then $s = '-'
    Return $s
EndFunc

Func _ChessCore_ParseCastlingRights($sRights)
    If $sRights == '-' Then Return 0
    If StringLen($sRights) < 1 Or StringLen($sRights) > 4 Then Return SetError(1, 0, -1)
    Local $mask = 0
    For $i = 1 To StringLen($sRights)
        Local $c = StringMid($sRights, $i, 1)
        ; FEN castling letters are case-sensitive; do not use Switch here.
        If $c == 'K' Then
            If BitAND($mask, $CASTLE_WK) Then Return SetError(2, 0, -1)
            $mask = BitOR($mask, $CASTLE_WK)
        ElseIf $c == 'Q' Then
            If BitAND($mask, $CASTLE_WQ) Then Return SetError(2, 0, -1)
            $mask = BitOR($mask, $CASTLE_WQ)
        ElseIf $c == 'k' Then
            If BitAND($mask, $CASTLE_BK) Then Return SetError(2, 0, -1)
            $mask = BitOR($mask, $CASTLE_BK)
        ElseIf $c == 'q' Then
            If BitAND($mask, $CASTLE_BQ) Then Return SetError(2, 0, -1)
            $mask = BitOR($mask, $CASTLE_BQ)
        Else
            Return SetError(3, 0, -1)
        EndIf
    Next
    Return $mask
EndFunc

Func ChessCore_SetCastlingRights($sRights)
    Local $mask = _ChessCore_ParseCastlingRights($sRights)
    If @error Then Return SetError(@error, 0, 0)
    $g_CastlingRights = $mask
    _ChessCore_ClearMoveStack()
    _ChessCore_ClearCommittedHistory()
    _Core_RebuildPositionHash()
    _Core_GameHistoryPushHash()
    Return 1
EndFunc

Func ChessCore_GetSideToMove()
    Return $g_SideToMove
EndFunc

Func ChessCore_SetSideToMove($sSide)
    If $sSide <> 'w' And $sSide <> 'b' Then Return SetError(1, 0, 0)
    $g_SideToMove = $sSide
    _ChessCore_ClearMoveStack()
    _ChessCore_ClearCommittedHistory()
    _Core_RebuildPositionHash()
    _Core_GameHistoryPushHash()
    Return 1
EndFunc

Func ChessCore_GetEnPassantSquare()
    Return $g_EnPassant
EndFunc

Func ChessCore_SetEnPassantSquare($iSquare)
    If $iSquare < -1 Or $iSquare > 63 Then Return SetError(1, 0, 0)
    $g_EnPassant = $iSquare
    _ChessCore_ClearMoveStack()
    _ChessCore_ClearCommittedHistory()
    _Core_RebuildPositionHash()
    _Core_GameHistoryPushHash()
    Return 1
EndFunc

; ============================== Attack Detection ===============================
Func _ChessCore_OppositeSide($sSide)
    Return ($sSide = 'w') ? 'b' : 'w'
EndFunc

Func _ChessCore_FindKingOnBoard(Const ByRef $aBoard, $sSide)
    Local $king = ($sSide = 'w') ? $PIECE_WHITE_KING : $PIECE_BLACK_KING
    For $sq = 0 To 63
        If $aBoard[$sq] = $king Then Return $sq
    Next
    Return -1
EndFunc

Func _ChessCore_IsSquareAttackedOnBoard(Const ByRef $aBoard, $iSquare, $sBySide)
    If $iSquare < 0 Or $iSquare > 63 Then Return False
    Local $file = Mod($iSquare, 8)
    Local $rank = Int($iSquare / 8)

    ; Pawn attacks
    Local $pawn = ($sBySide = 'w') ? $PIECE_WHITE_PAWN : $PIECE_BLACK_PAWN
    Local $pawnRank = ($sBySide = 'w') ? $rank - 1 : $rank + 1
    If $pawnRank >= 0 And $pawnRank <= 7 Then
        If $file > 0 And $aBoard[$pawnRank * 8 + $file - 1] = $pawn Then Return True
        If $file < 7 And $aBoard[$pawnRank * 8 + $file + 1] = $pawn Then Return True
    EndIf

    ; Knights
    Local $knight = ($sBySide = 'w') ? $PIECE_WHITE_KNIGHT : $PIECE_BLACK_KNIGHT
    Local $kdf[8] = [-2,-2,-1,-1,1,1,2,2]
    Local $kdr[8] = [-1,1,-2,2,-2,2,-1,1]
    For $i = 0 To 7
        Local $nf = $file + $kdf[$i], $nr = $rank + $kdr[$i]
        If $nf >= 0 And $nf <= 7 And $nr >= 0 And $nr <= 7 Then
            If $aBoard[$nr * 8 + $nf] = $knight Then Return True
        EndIf
    Next

    ; King
    Local $king = ($sBySide = 'w') ? $PIECE_WHITE_KING : $PIECE_BLACK_KING
    For $df = -1 To 1
        For $dr = -1 To 1
            If $df = 0 And $dr = 0 Then ContinueLoop
            Local $nf = $file + $df, $nr = $rank + $dr
            If $nf >= 0 And $nf <= 7 And $nr >= 0 And $nr <= 7 Then
                If $aBoard[$nr * 8 + $nf] = $king Then Return True
            EndIf
        Next
    Next

    ; Diagonal sliders
    Local $bishop = ($sBySide = 'w') ? $PIECE_WHITE_BISHOP : $PIECE_BLACK_BISHOP
    Local $queen = ($sBySide = 'w') ? $PIECE_WHITE_QUEEN : $PIECE_BLACK_QUEEN
    Local $bdf[4] = [-1,-1,1,1]
    Local $bdr[4] = [-1,1,-1,1]
    For $d = 0 To 3
        Local $nf = $file + $bdf[$d], $nr = $rank + $bdr[$d]
        While $nf >= 0 And $nf <= 7 And $nr >= 0 And $nr <= 7
            Local $p = $aBoard[$nr * 8 + $nf]
            If $p <> $PIECE_EMPTY Then
                If $p = $bishop Or $p = $queen Then Return True
                ExitLoop
            EndIf
            $nf += $bdf[$d]
            $nr += $bdr[$d]
        WEnd
    Next

    ; Orthogonal sliders
    Local $rook = ($sBySide = 'w') ? $PIECE_WHITE_ROOK : $PIECE_BLACK_ROOK
    Local $rdf[4] = [-1,1,0,0]
    Local $rdr[4] = [0,0,-1,1]
    For $d = 0 To 3
        Local $nf = $file + $rdf[$d], $nr = $rank + $rdr[$d]
        While $nf >= 0 And $nf <= 7 And $nr >= 0 And $nr <= 7
            Local $p = $aBoard[$nr * 8 + $nf]
            If $p <> $PIECE_EMPTY Then
                If $p = $rook Or $p = $queen Then Return True
                ExitLoop
            EndIf
            $nf += $rdf[$d]
            $nr += $rdr[$d]
        WEnd
    Next

    Return False
EndFunc

; ============================== FEN ============================================
Func _ChessCore_ParseFEN($sFEN, ByRef $aBoard, ByRef $sSide, ByRef $iCastling, ByRef $iEP, ByRef $iHalf, ByRef $iFull)
    $sFEN = StringRegExpReplace(StringStripWS($sFEN, 3), '[ \t]+', ' ')
    If StringLen($sFEN) = 0 Then Return SetError(1, 0, False)
    Local $parts = StringSplit($sFEN, ' ', 2)
    If UBound($parts) <> 6 Then Return SetError(2, 0, False)

    For $i = 0 To 63
        $aBoard[$i] = $PIECE_EMPTY
    Next

    Local $ranks = StringSplit($parts[0], '/', 2)
    If UBound($ranks) <> 8 Then Return SetError(3, 0, False)

    Local $wk = 0, $bk = 0, $wp = 0, $bp = 0, $whitePieces = 0, $blackPieces = 0
    For $fenRank = 0 To 7
        Local $text = $ranks[$fenRank]
        If StringLen($text) = 0 Then Return SetError(4, 0, False)
        Local $file = 0
        For $j = 1 To StringLen($text)
            Local $c = StringMid($text, $j, 1)
            If StringRegExp($c, '^[1-8]$') Then
                $file += Int($c)
            Else
                Local $p = _ChessCore_CharToPiece($c)
                If @error Then Return SetError(5, 0, False)
                If $file > 7 Then Return SetError(6, 0, False)
                Local $boardRank = 7 - $fenRank
                Local $sq = $boardRank * 8 + $file
                $aBoard[$sq] = $p
                If $p = $PIECE_WHITE_KING Then $wk += 1
                If $p = $PIECE_BLACK_KING Then $bk += 1
                If $p = $PIECE_WHITE_PAWN Then $wp += 1
                If $p = $PIECE_BLACK_PAWN Then $bp += 1
                If _ChessCore_IsWhitePiece($p) Then $whitePieces += 1
                If _ChessCore_IsBlackPiece($p) Then $blackPieces += 1
                If _ChessCore_IsPawn($p) And ($boardRank = 0 Or $boardRank = 7) Then Return SetError(7, 0, False)
                $file += 1
            EndIf
            If $file > 8 Then Return SetError(8, 0, False)
        Next
        If $file <> 8 Then Return SetError(9, 0, False)
    Next

    If $wk <> 1 Or $bk <> 1 Then Return SetError(10, 0, False)
    If $wp > 8 Or $bp > 8 Then Return SetError(11, 0, False)
    If $whitePieces > 16 Or $blackPieces > 16 Then Return SetError(12, 0, False)

    $sSide = $parts[1]
    If Not ($sSide == 'w' Or $sSide == 'b') Then Return SetError(13, 0, False)

    Local $whiteKing = -1, $blackKing = -1
    For $i = 0 To 63
        If $aBoard[$i] = $PIECE_WHITE_KING Then $whiteKing = $i
        If $aBoard[$i] = $PIECE_BLACK_KING Then $blackKing = $i
    Next
    Local $wkf = Mod($whiteKing, 8), $wkr = Int($whiteKing / 8)
    Local $bkf = Mod($blackKing, 8), $bkr = Int($blackKing / 8)
    If Abs($wkf - $bkf) <= 1 And Abs($wkr - $bkr) <= 1 Then Return SetError(14, 0, False)

    ; The player who just moved cannot have left their own king in check.
    If $sSide = 'w' Then
        If _ChessCore_IsSquareAttackedOnBoard($aBoard, $blackKing, 'w') Then Return SetError(15, 0, False)
    Else
        If _ChessCore_IsSquareAttackedOnBoard($aBoard, $whiteKing, 'b') Then Return SetError(16, 0, False)
    EndIf

    $iCastling = _ChessCore_ParseCastlingRights($parts[2])
    If @error Then Return SetError(17, 0, False)

    If BitAND($iCastling, $CASTLE_WK) Then
        If $aBoard[4] <> $PIECE_WHITE_KING Or $aBoard[7] <> $PIECE_WHITE_ROOK Then Return SetError(18, 0, False)
    EndIf
    If BitAND($iCastling, $CASTLE_WQ) Then
        If $aBoard[4] <> $PIECE_WHITE_KING Or $aBoard[0] <> $PIECE_WHITE_ROOK Then Return SetError(19, 0, False)
    EndIf
    If BitAND($iCastling, $CASTLE_BK) Then
        If $aBoard[60] <> $PIECE_BLACK_KING Or $aBoard[63] <> $PIECE_BLACK_ROOK Then Return SetError(20, 0, False)
    EndIf
    If BitAND($iCastling, $CASTLE_BQ) Then
        If $aBoard[60] <> $PIECE_BLACK_KING Or $aBoard[56] <> $PIECE_BLACK_ROOK Then Return SetError(21, 0, False)
    EndIf

    $iEP = -1
    If $parts[3] <> '-' Then
        Local $ep = ChessCore_SquareToIndex($parts[3])
        If @error Or $ep < 0 Then Return SetError(22, 0, False)
        Local $epFile, $epRank
        ChessCore_IndexToFileRank($ep, $epFile, $epRank)
        If $sSide = 'w' Then
            If $epRank <> 5 Then Return SetError(23, 0, False)
            If $aBoard[$ep] <> $PIECE_EMPTY Then Return SetError(24, 0, False)
            If $aBoard[$ep - 8] <> $PIECE_BLACK_PAWN Then Return SetError(25, 0, False)
            If $aBoard[$ep + 8] <> $PIECE_EMPTY Then Return SetError(26, 0, False)
        Else
            If $epRank <> 2 Then Return SetError(27, 0, False)
            If $aBoard[$ep] <> $PIECE_EMPTY Then Return SetError(28, 0, False)
            If $aBoard[$ep + 8] <> $PIECE_WHITE_PAWN Then Return SetError(29, 0, False)
            If $aBoard[$ep - 8] <> $PIECE_EMPTY Then Return SetError(30, 0, False)
        EndIf
        $iEP = $ep
    EndIf

    If Not StringRegExp($parts[4], '^\d+$') Then Return SetError(31, 0, False)
    If Not StringRegExp($parts[5], '^\d+$') Then Return SetError(32, 0, False)
    $iHalf = Int($parts[4])
    $iFull = Int($parts[5])
    If $iFull < 1 Then Return SetError(33, 0, False)

    Return 1
EndFunc

Func ChessCore_ValidateFEN($sFEN)
    Local $aBoard[64], $side, $castle, $ep, $half, $full
    Return _ChessCore_ParseFEN($sFEN, $aBoard, $side, $castle, $ep, $half, $full)
EndFunc

Func ChessCore_SetFEN($sFEN)
    Local $aTemp[64], $side, $castle, $ep, $half, $full
    If Not _ChessCore_ParseFEN($sFEN, $aTemp, $side, $castle, $ep, $half, $full) Then Return SetError(@error, 0, 0)
    For $i = 0 To 63
        $g_Board[$i] = $aTemp[$i]
    Next
    $g_SideToMove = $side
    $g_CastlingRights = $castle
    $g_EnPassant = $ep
    $g_HalfmoveClock = $half
    $g_FullmoveNumber = $full
    _ChessCore_RebuildKingCache()
    _ChessCore_ClearMoveStack()
    _ChessCore_ClearCommittedHistory()
    _Core_RebuildPositionHash()
    _Core_GameHistoryPushHash()
    Return 1
EndFunc

Func ChessCore_GetFEN()
    Local $s = ''
    For $rank = 7 To 0 Step -1
        Local $empty = 0
        For $file = 0 To 7
            Local $piece = $g_Board[$rank * 8 + $file]
            If $piece = $PIECE_EMPTY Then
                $empty += 1
            Else
                If $empty > 0 Then
                    $s &= $empty
                    $empty = 0
                EndIf
                $s &= _ChessCore_PieceToChar($piece)
            EndIf
        Next
        If $empty > 0 Then $s &= $empty
        If $rank > 0 Then $s &= '/'
    Next
    $s &= ' ' & $g_SideToMove & ' ' & ChessCore_GetCastlingRights() & ' '
    If $g_EnPassant >= 0 Then
        $s &= ChessCore_IndexToSquare($g_EnPassant)
    Else
        $s &= '-'
    EndIf
    Return $s & ' ' & $g_HalfmoveClock & ' ' & $g_FullmoveNumber
EndFunc

; ============================== Zobrist Engine =================================
Func _Core_Random32()
    ; Build a signed 32-bit value from four independent 8-bit chunks. The
    ; exact sign is irrelevant; AutoIt's BitXOR treats the value as 32 bits.
    Local $a = Random(0, 255, 1)
    Local $b = Random(0, 255, 1)
    Local $c = Random(0, 255, 1)
    Local $d = Random(0, 255, 1)
    Return BitOR($a, BitShift($b, -8), BitShift($c, -16), BitShift($d, -24))
EndFunc

Func _Core_InitZobrist()
    If $g_ZobristReady Then Return
    For $p = 0 To 12
        For $sq = 0 To 63
            $g_ZobristPieceHi[$p][$sq] = _Core_Random32()
            $g_ZobristPieceLo[$p][$sq] = _Core_Random32()
        Next
    Next
    $g_ZobristSideHi = _Core_Random32()
    $g_ZobristSideLo = _Core_Random32()
    For $i = 0 To 15
        $g_ZobristCastleHi[$i] = _Core_Random32()
        $g_ZobristCastleLo[$i] = _Core_Random32()
    Next
    For $i = 0 To 7
        $g_ZobristEPFileHi[$i] = _Core_Random32()
        $g_ZobristEPFileLo[$i] = _Core_Random32()
    Next
    $g_ZobristReady = True
EndFunc

Func _Core_HashXorPair($hi, $lo)
    $g_ZobristHashHi = BitXOR($g_ZobristHashHi, $hi)
    $g_ZobristHashLo = BitXOR($g_ZobristHashLo, $lo)
EndFunc

Func _Core_HashAddPiece($iPiece, $iSquare)
    If $iPiece = $PIECE_EMPTY Then Return
    _Core_HashXorPair($g_ZobristPieceHi[$iPiece][$iSquare], $g_ZobristPieceLo[$iPiece][$iSquare])
EndFunc

Func _Core_HasLegalEPCapture($iEPSquare, $sCapturingSide)
    Local $epFile = Mod($iEPSquare, 8)
    Local $epRank = Int($iEPSquare / 8)
    Local $pawn = ($sCapturingSide = 'w') ? $PIECE_WHITE_PAWN : $PIECE_BLACK_PAWN
    Local $fromRank = ($sCapturingSide = 'w') ? $epRank - 1 : $epRank + 1
    If $fromRank < 0 Or $fromRank > 7 Then Return False

    Local $victimSquare = ($sCapturingSide = 'w') ? $iEPSquare - 8 : $iEPSquare + 8
    If $victimSquare < 0 Or $victimSquare > 63 Then Return False
    Local $victimPiece = $g_Board[$victimSquare]
    If $victimPiece <> (($sCapturingSide = 'w') ? $PIECE_BLACK_PAWN : $PIECE_WHITE_PAWN) Then Return False

    For $df = -1 To 1 Step 2
        Local $fromFile = $epFile + $df
        If $fromFile < 0 Or $fromFile > 7 Then ContinueLoop
        Local $fromSquare = $fromRank * 8 + $fromFile
        If $g_Board[$fromSquare] <> $pawn Then ContinueLoop

        $g_Board[$fromSquare] = $PIECE_EMPTY
        $g_Board[$victimSquare] = $PIECE_EMPTY
        $g_Board[$iEPSquare] = $pawn
        Local $kingSquare = ($sCapturingSide = 'w') ? $g_WhiteKingSquare : $g_BlackKingSquare
        Local $safe = Not _ChessCore_IsSquareAttackedOnBoard($g_Board, $kingSquare, _ChessCore_OppositeSide($sCapturingSide))
        $g_Board[$fromSquare] = $pawn
        $g_Board[$victimSquare] = $victimPiece
        $g_Board[$iEPSquare] = $PIECE_EMPTY
        If $safe Then Return True
    Next
    Return False
EndFunc

Func _Core_NormalizedEPFile()
    If $g_EnPassant < 0 Then Return -1
    If _Core_HasLegalEPCapture($g_EnPassant, $g_SideToMove) Then Return Mod($g_EnPassant, 8)
    Return -1
EndFunc

Func _Core_RebuildPositionHash()
    If Not $g_ZobristReady Then _Core_InitZobrist()
    $g_ZobristHashHi = 0
    $g_ZobristHashLo = 0
    For $sq = 0 To 63
        _Core_HashAddPiece($g_Board[$sq], $sq)
    Next
    If $g_SideToMove = 'b' Then _Core_HashXorPair($g_ZobristSideHi, $g_ZobristSideLo)
    _Core_HashXorPair($g_ZobristCastleHi[$g_CastlingRights], $g_ZobristCastleLo[$g_CastlingRights])
    $g_ZobristEPFileActive = _Core_NormalizedEPFile()
    If $g_ZobristEPFileActive <> -1 Then _Core_HashXorPair($g_ZobristEPFileHi[$g_ZobristEPFileActive], $g_ZobristEPFileLo[$g_ZobristEPFileActive])
EndFunc

Func ChessCore_GetPositionHash()
    Return StringFormat('%08X%08X', $g_ZobristHashHi, $g_ZobristHashLo)
EndFunc

Func ChessCore_GetPositionHashHi()
    Return $g_ZobristHashHi
EndFunc

Func ChessCore_GetPositionHashLo()
    Return $g_ZobristHashLo
EndFunc

; ============================== History ========================================
Func _Core_EnsureMoveCapacity()
    If $g_MoveStackCount < $g_MoveStackCapacity Then Return
    $g_MoveStackCapacity *= 2
    ReDim $g_MoveStackMove[$g_MoveStackCapacity]
    ReDim $g_MoveStackCaptured[$g_MoveStackCapacity]
    ReDim $g_MoveStackCastling[$g_MoveStackCapacity]
    ReDim $g_MoveStackEP[$g_MoveStackCapacity]
    ReDim $g_MoveStackHalfmove[$g_MoveStackCapacity]
    ReDim $g_MoveStackFullmove[$g_MoveStackCapacity]
    ReDim $g_MoveStackHashHi[$g_MoveStackCapacity]
    ReDim $g_MoveStackHashLo[$g_MoveStackCapacity]
    ReDim $g_MoveStackEPHashFile[$g_MoveStackCapacity]
    ReDim $g_MoveStackWhiteKing[$g_MoveStackCapacity]
    ReDim $g_MoveStackBlackKing[$g_MoveStackCapacity]
EndFunc

Func _Core_EnsureGameHistoryCapacity()
    If $g_GameHistoryCount < $g_GameHistoryCapacity Then Return
    $g_GameHistoryCapacity *= 2
    ReDim $g_GameHistoryMove[$g_GameHistoryCapacity]
    ReDim $g_GameHistoryHashHi[$g_GameHistoryCapacity]
    ReDim $g_GameHistoryHashLo[$g_GameHistoryCapacity]
EndFunc

Func _Core_GameHistoryPushHash()
    _Core_EnsureGameHistoryCapacity()
    $g_GameHistoryMove[$g_GameHistoryCount] = 0
    $g_GameHistoryHashHi[$g_GameHistoryCount] = $g_ZobristHashHi
    $g_GameHistoryHashLo[$g_GameHistoryCount] = $g_ZobristHashLo
    $g_GameHistoryCount += 1
EndFunc

Func _Core_GameHistoryPushMove($iMove)
    _Core_EnsureGameHistoryCapacity()
    $g_GameHistoryMove[$g_GameHistoryCount] = $iMove
    $g_GameHistoryHashHi[$g_GameHistoryCount] = $g_ZobristHashHi
    $g_GameHistoryHashLo[$g_GameHistoryCount] = $g_ZobristHashLo
    $g_GameHistoryCount += 1
EndFunc

Func _Core_GameHistoryPop()
    If $g_GameHistoryCount <= 0 Then Return SetError(1, 0, 0)
    $g_GameHistoryCount -= 1
    Return 1
EndFunc

Func ChessCore_GetMoveHistoryCount()
    ; Initial position is not a move, therefore report committed moves only.
    If $g_GameHistoryCount <= 0 Then Return 0
    Return $g_GameHistoryCount - 1
EndFunc

Func ChessCore_GetMoveHistory()
    Local $n = ChessCore_GetMoveHistoryCount()
    If $n <= 0 Then
        Local $empty[1] = ['']
        Return $empty
    EndIf
    Local $history[$n]
    For $i = 0 To $n - 1
        $history[$i] = Core_MoveToUCI($g_GameHistoryMove[$i + 1])
    Next
    Return $history
EndFunc

Func ChessCore_CountRepetitions()
    Local $count = 0
    For $i = 0 To $g_GameHistoryCount - 1
        If $g_GameHistoryHashHi[$i] = $g_ZobristHashHi And $g_GameHistoryHashLo[$i] = $g_ZobristHashLo Then $count += 1
    Next
    Return $count
EndFunc

; ============================== UCI ============================================
Func ChessCore_ParseUCI($sUCI, ByRef $iFrom, ByRef $iTo, ByRef $iPromo)
    $iFrom = -1
    $iTo = -1
    $iPromo = $PIECE_EMPTY
    If StringLen($sUCI) <> 4 And StringLen($sUCI) <> 5 Then Return SetError(1, 0, False)
    $iFrom = ChessCore_SquareToIndex(StringLeft($sUCI, 2))
    If @error Then Return SetError(2, 0, False)
    $iTo = ChessCore_SquareToIndex(StringMid($sUCI, 3, 2))
    If @error Then Return SetError(3, 0, False)
    If StringLen($sUCI) = 5 Then
        Switch StringLower(StringRight($sUCI, 1))
            Case 'q'
                $iPromo = $PIECE_WHITE_QUEEN
            Case 'r'
                $iPromo = $PIECE_WHITE_ROOK
            Case 'b'
                $iPromo = $PIECE_WHITE_BISHOP
            Case 'n'
                $iPromo = $PIECE_WHITE_KNIGHT
            Case Else
                Return SetError(4, 0, False)
        EndSwitch
    EndIf
    Return 1
EndFunc

Func ChessCore_FormatUCI($iFrom, $iTo, $iPromo = $PIECE_EMPTY)
    Local $s = ChessCore_IndexToSquare($iFrom) & ChessCore_IndexToSquare($iTo)
    If @error Then Return SetError(1, 0, '')
    If $iPromo <> $PIECE_EMPTY Then
        Switch $iPromo
            Case $PIECE_WHITE_QUEEN
                $s &= 'q'
            Case $PIECE_WHITE_ROOK
                $s &= 'r'
            Case $PIECE_WHITE_BISHOP
                $s &= 'b'
            Case $PIECE_WHITE_KNIGHT
                $s &= 'n'
            Case Else
                Return SetError(2, 0, '')
        EndSwitch
    EndIf
    Return $s
EndFunc

Func Core_MoveToUCI($iMove)
    Return ChessCore_FormatUCI(_Core_MoveFrom($iMove), _Core_MoveTo($iMove), _Core_MovePromo($iMove))
EndFunc

; ============================== Move Generation ================================
Func _ChessCore_IsFriendlyPiece($iPiece, $sSide)
    If $iPiece = $PIECE_EMPTY Then Return False
    Return ($sSide = 'w') ? _ChessCore_IsWhitePiece($iPiece) : _ChessCore_IsBlackPiece($iPiece)
EndFunc

Func _ChessCore_IsEnemyNonKing($iPiece, $sSide)
    If $iPiece = $PIECE_EMPTY Or _ChessCore_IsKing($iPiece) Then Return False
    Return ($sSide = 'w') ? _ChessCore_IsBlackPiece($iPiece) : _ChessCore_IsWhitePiece($iPiece)
EndFunc

Func _Core_AddPackedMove(ByRef $aMoves, ByRef $iCount, $iMove)
    If $iCount >= UBound($aMoves) Then ReDim $aMoves[UBound($aMoves) * 2]
    $aMoves[$iCount] = $iMove
    $iCount += 1
EndFunc

Func _Core_AddPromotionSet(ByRef $aMoves, ByRef $iCount, $iFrom, $iTo, $iBaseFlags)
    _Core_AddPackedMove($aMoves, $iCount, _Core_EncodeMove($iFrom, $iTo, $PIECE_WHITE_QUEEN, BitOR($iBaseFlags, $MOVE_FLAG_PROMOTION)))
    _Core_AddPackedMove($aMoves, $iCount, _Core_EncodeMove($iFrom, $iTo, $PIECE_WHITE_ROOK, BitOR($iBaseFlags, $MOVE_FLAG_PROMOTION)))
    _Core_AddPackedMove($aMoves, $iCount, _Core_EncodeMove($iFrom, $iTo, $PIECE_WHITE_BISHOP, BitOR($iBaseFlags, $MOVE_FLAG_PROMOTION)))
    _Core_AddPackedMove($aMoves, $iCount, _Core_EncodeMove($iFrom, $iTo, $PIECE_WHITE_KNIGHT, BitOR($iBaseFlags, $MOVE_FLAG_PROMOTION)))
EndFunc

Func _Core_GeneratePseudoMovesPacked()
    Local $moves[256]
    Local $count = 0
    Local $side = $g_SideToMove

    For $from = 0 To 63
        Local $piece = $g_Board[$from]
        If Not _ChessCore_IsFriendlyPiece($piece, $side) Then ContinueLoop
        Local $file = Mod($from, 8), $rank = Int($from / 8)

        Switch $piece
            Case $PIECE_WHITE_PAWN, $PIECE_BLACK_PAWN
                Local $dir = ($piece = $PIECE_WHITE_PAWN) ? 1 : -1
                Local $startRank = ($piece = $PIECE_WHITE_PAWN) ? 1 : 6
                Local $promoRank = ($piece = $PIECE_WHITE_PAWN) ? 7 : 0
                Local $oneRank = $rank + $dir

                If $oneRank >= 0 And $oneRank <= 7 Then
                    Local $to = $oneRank * 8 + $file
                    If $g_Board[$to] = $PIECE_EMPTY Then
                        If $oneRank = $promoRank Then
                            _Core_AddPromotionSet($moves, $count, $from, $to, $MOVE_FLAG_NORMAL)
                        Else
                            _Core_AddPackedMove($moves, $count, _Core_EncodeMove($from, $to))
                            If $rank = $startRank Then
                                Local $to2 = ($rank + 2 * $dir) * 8 + $file
                                If $g_Board[$to2] = $PIECE_EMPTY Then _Core_AddPackedMove($moves, $count, _Core_EncodeMove($from, $to2, $PIECE_EMPTY, $MOVE_FLAG_DOUBLE_PAWN))
                            EndIf
                        EndIf
                    EndIf
                EndIf

                For $df = -1 To 1 Step 2
                    Local $cf = $file + $df, $cr = $rank + $dir
                    If $cf < 0 Or $cf > 7 Or $cr < 0 Or $cr > 7 Then ContinueLoop
                    Local $to = $cr * 8 + $cf
                    If _ChessCore_IsEnemyNonKing($g_Board[$to], $side) Then
                        If $cr = $promoRank Then
                            _Core_AddPromotionSet($moves, $count, $from, $to, $MOVE_FLAG_CAPTURE)
                        Else
                            _Core_AddPackedMove($moves, $count, _Core_EncodeMove($from, $to, $PIECE_EMPTY, $MOVE_FLAG_CAPTURE))
                        EndIf
                    ElseIf $to = $g_EnPassant And $g_Board[$to] = $PIECE_EMPTY Then
                        Local $victim = ($piece = $PIECE_WHITE_PAWN) ? $to - 8 : $to + 8
                        If $victim >= 0 And $victim <= 63 Then
                            Local $victimPiece = ($piece = $PIECE_WHITE_PAWN) ? $PIECE_BLACK_PAWN : $PIECE_WHITE_PAWN
                            If $g_Board[$victim] = $victimPiece Then _Core_AddPackedMove($moves, $count, _Core_EncodeMove($from, $to, $PIECE_EMPTY, BitOR($MOVE_FLAG_EN_PASSANT, $MOVE_FLAG_CAPTURE)))
                        EndIf
                    EndIf
                Next

            Case $PIECE_WHITE_KNIGHT, $PIECE_BLACK_KNIGHT
                Local $df[8] = [-2,-2,-1,-1,1,1,2,2]
                Local $dr[8] = [-1,1,-2,2,-2,2,-1,1]
                For $i = 0 To 7
                    Local $nf = $file + $df[$i], $nr = $rank + $dr[$i]
                    If $nf < 0 Or $nf > 7 Or $nr < 0 Or $nr > 7 Then ContinueLoop
                    Local $to = $nr * 8 + $nf
                    Local $tp = $g_Board[$to]
                    If $tp = $PIECE_EMPTY Then
                        _Core_AddPackedMove($moves, $count, _Core_EncodeMove($from, $to))
                    ElseIf _ChessCore_IsEnemyNonKing($tp, $side) Then
                        _Core_AddPackedMove($moves, $count, _Core_EncodeMove($from, $to, $PIECE_EMPTY, $MOVE_FLAG_CAPTURE))
                    EndIf
                Next

            Case $PIECE_WHITE_BISHOP, $PIECE_BLACK_BISHOP, $PIECE_WHITE_ROOK, $PIECE_BLACK_ROOK, $PIECE_WHITE_QUEEN, $PIECE_BLACK_QUEEN
                Local $df[8], $dr[8], $dirCount
                If $piece = $PIECE_WHITE_BISHOP Or $piece = $PIECE_BLACK_BISHOP Then
                    Local $bdf[4] = [-1,-1,1,1], $bdr[4] = [-1,1,-1,1]
                    $dirCount = 4
                    For $d = 0 To 3
                        $df[$d] = $bdf[$d]
                        $dr[$d] = $bdr[$d]
                    Next
                ElseIf $piece = $PIECE_WHITE_ROOK Or $piece = $PIECE_BLACK_ROOK Then
                    Local $rdf[4] = [-1,1,0,0], $rdr[4] = [0,0,-1,1]
                    $dirCount = 4
                    For $d = 0 To 3
                        $df[$d] = $rdf[$d]
                        $dr[$d] = $rdr[$d]
                    Next
                Else
                    Local $qdf[8] = [-1,-1,1,1,-1,1,0,0], $qdr[8] = [-1,1,-1,1,0,0,-1,1]
                    $dirCount = 8
                    For $d = 0 To 7
                        $df[$d] = $qdf[$d]
                        $dr[$d] = $qdr[$d]
                    Next
                EndIf

                For $d = 0 To $dirCount - 1
                    Local $nf = $file + $df[$d], $nr = $rank + $dr[$d]
                    While $nf >= 0 And $nf <= 7 And $nr >= 0 And $nr <= 7
                        Local $to = $nr * 8 + $nf
                        Local $tp = $g_Board[$to]
                        If $tp = $PIECE_EMPTY Then
                            _Core_AddPackedMove($moves, $count, _Core_EncodeMove($from, $to))
                        Else
                            If _ChessCore_IsEnemyNonKing($tp, $side) Then _Core_AddPackedMove($moves, $count, _Core_EncodeMove($from, $to, $PIECE_EMPTY, $MOVE_FLAG_CAPTURE))
                            ExitLoop
                        EndIf
                        $nf += $df[$d]
                        $nr += $dr[$d]
                    WEnd
                Next

            Case $PIECE_WHITE_KING, $PIECE_BLACK_KING
                For $df = -1 To 1
                    For $dr = -1 To 1
                        If $df = 0 And $dr = 0 Then ContinueLoop
                        Local $nf = $file + $df, $nr = $rank + $dr
                        If $nf < 0 Or $nf > 7 Or $nr < 0 Or $nr > 7 Then ContinueLoop
                        Local $to = $nr * 8 + $nf
                        Local $tp = $g_Board[$to]
                        If $tp = $PIECE_EMPTY Then
                            _Core_AddPackedMove($moves, $count, _Core_EncodeMove($from, $to))
                        ElseIf _ChessCore_IsEnemyNonKing($tp, $side) Then
                            _Core_AddPackedMove($moves, $count, _Core_EncodeMove($from, $to, $PIECE_EMPTY, $MOVE_FLAG_CAPTURE))
                        EndIf
                    Next
                Next

                ; Standard chess castling geometry.
                If $piece = $PIECE_WHITE_KING And $from = 4 Then
                    If BitAND($g_CastlingRights, $CASTLE_WK) And $g_Board[7] = $PIECE_WHITE_ROOK And $g_Board[5] = $PIECE_EMPTY And $g_Board[6] = $PIECE_EMPTY Then
                        If Not _ChessCore_IsSquareAttackedOnBoard($g_Board, 4, 'b') And Not _ChessCore_IsSquareAttackedOnBoard($g_Board, 5, 'b') And Not _ChessCore_IsSquareAttackedOnBoard($g_Board, 6, 'b') Then _Core_AddPackedMove($moves, $count, _Core_EncodeMove(4, 6, $PIECE_EMPTY, $MOVE_FLAG_CASTLING))
                    EndIf
                    If BitAND($g_CastlingRights, $CASTLE_WQ) And $g_Board[0] = $PIECE_WHITE_ROOK And $g_Board[1] = $PIECE_EMPTY And $g_Board[2] = $PIECE_EMPTY And $g_Board[3] = $PIECE_EMPTY Then
                        If Not _ChessCore_IsSquareAttackedOnBoard($g_Board, 4, 'b') And Not _ChessCore_IsSquareAttackedOnBoard($g_Board, 3, 'b') And Not _ChessCore_IsSquareAttackedOnBoard($g_Board, 2, 'b') Then _Core_AddPackedMove($moves, $count, _Core_EncodeMove(4, 2, $PIECE_EMPTY, $MOVE_FLAG_CASTLING))
                    EndIf
                ElseIf $piece = $PIECE_BLACK_KING And $from = 60 Then
                    If BitAND($g_CastlingRights, $CASTLE_BK) And $g_Board[63] = $PIECE_BLACK_ROOK And $g_Board[61] = $PIECE_EMPTY And $g_Board[62] = $PIECE_EMPTY Then
                        If Not _ChessCore_IsSquareAttackedOnBoard($g_Board, 60, 'w') And Not _ChessCore_IsSquareAttackedOnBoard($g_Board, 61, 'w') And Not _ChessCore_IsSquareAttackedOnBoard($g_Board, 62, 'w') Then _Core_AddPackedMove($moves, $count, _Core_EncodeMove(60, 62, $PIECE_EMPTY, $MOVE_FLAG_CASTLING))
                    EndIf
                    If BitAND($g_CastlingRights, $CASTLE_BQ) And $g_Board[56] = $PIECE_BLACK_ROOK And $g_Board[57] = $PIECE_EMPTY And $g_Board[58] = $PIECE_EMPTY And $g_Board[59] = $PIECE_EMPTY Then
                        If Not _ChessCore_IsSquareAttackedOnBoard($g_Board, 60, 'w') And Not _ChessCore_IsSquareAttackedOnBoard($g_Board, 59, 'w') And Not _ChessCore_IsSquareAttackedOnBoard($g_Board, 58, 'w') Then _Core_AddPackedMove($moves, $count, _Core_EncodeMove(60, 58, $PIECE_EMPTY, $MOVE_FLAG_CASTLING))
                    EndIf
                EndIf
        EndSwitch
    Next

    ReDim $moves[$count]
    Return $moves
EndFunc

Func _ChessCore_GeneratePseudoMoves()
    Local $packed = _Core_GeneratePseudoMovesPacked()
    Local $n = UBound($packed)
    If $n = 0 Then
        Local $empty[1] = ['']
        Return $empty
    EndIf
    Local $moves[$n]
    For $i = 0 To $n - 1
        $moves[$i] = Core_MoveToUCI($packed[$i])
    Next
    Return $moves
EndFunc

Func ChessCore_GetMoveCount(Const ByRef $aMoves)
    Local $n = UBound($aMoves)
    If $n = 1 And $aMoves[0] = '' Then Return 0
    Return $n
EndFunc

; ============================== Move Application ===============================
Func _ChessCore_IsValidPromotionPiece($iPromo)
    Return $iPromo = $PIECE_WHITE_QUEEN Or $iPromo = $PIECE_WHITE_ROOK Or $iPromo = $PIECE_WHITE_BISHOP Or $iPromo = $PIECE_WHITE_KNIGHT
EndFunc

Func _ChessCore_UpdateCastlingRightsOnMove(ByRef $iCastling, $iPiece, $iFrom, $iTo, $iCaptured)
    If $iPiece = $PIECE_WHITE_KING Then
        $iCastling = BitAND($iCastling, BitNOT(BitOR($CASTLE_WK, $CASTLE_WQ)))
    ElseIf $iPiece = $PIECE_BLACK_KING Then
        $iCastling = BitAND($iCastling, BitNOT(BitOR($CASTLE_BK, $CASTLE_BQ)))
    EndIf

    If $iPiece = $PIECE_WHITE_ROOK Then
        Switch $iFrom
            Case 0
                $iCastling = BitAND($iCastling, BitNOT($CASTLE_WQ))
            Case 7
                $iCastling = BitAND($iCastling, BitNOT($CASTLE_WK))
        EndSwitch
    ElseIf $iPiece = $PIECE_BLACK_ROOK Then
        Switch $iFrom
            Case 56
                $iCastling = BitAND($iCastling, BitNOT($CASTLE_BQ))
            Case 63
                $iCastling = BitAND($iCastling, BitNOT($CASTLE_BK))
        EndSwitch
    EndIf

    Switch $iTo
        Case 0
            If $iCaptured = $PIECE_WHITE_ROOK Then $iCastling = BitAND($iCastling, BitNOT($CASTLE_WQ))
        Case 7
            If $iCaptured = $PIECE_WHITE_ROOK Then $iCastling = BitAND($iCastling, BitNOT($CASTLE_WK))
        Case 56
            If $iCaptured = $PIECE_BLACK_ROOK Then $iCastling = BitAND($iCastling, BitNOT($CASTLE_BQ))
        Case 63
            If $iCaptured = $PIECE_BLACK_ROOK Then $iCastling = BitAND($iCastling, BitNOT($CASTLE_BK))
    EndSwitch
EndFunc

Func _Core_StoreMoveState($iMove, $iCaptured, $iPrevCastle, $iPrevEP, $iPrevHalf, $iPrevFull, $iPrevHashHi, $iPrevHashLo, $iPrevEPFile, $iPrevWK, $iPrevBK)
    _Core_EnsureMoveCapacity()
    Local $i = $g_MoveStackCount
    $g_MoveStackMove[$i] = $iMove
    $g_MoveStackCaptured[$i] = $iCaptured
    $g_MoveStackCastling[$i] = $iPrevCastle
    $g_MoveStackEP[$i] = $iPrevEP
    $g_MoveStackHalfmove[$i] = $iPrevHalf
    $g_MoveStackFullmove[$i] = $iPrevFull
    $g_MoveStackHashHi[$i] = $iPrevHashHi
    $g_MoveStackHashLo[$i] = $iPrevHashLo
    $g_MoveStackEPHashFile[$i] = $iPrevEPFile
    $g_MoveStackWhiteKing[$i] = $iPrevWK
    $g_MoveStackBlackKing[$i] = $iPrevBK
    $g_MoveStackCount += 1
EndFunc

Func Core_MakeMove($iMove)
    Local $from = _Core_MoveFrom($iMove)
    Local $to = _Core_MoveTo($iMove)
    Local $promo = _Core_MovePromo($iMove)
    Local $flags = _Core_MoveFlags($iMove)
    Local $piece = $g_Board[$from]
    Local $side = $g_SideToMove
    Local $white = ($side = 'w')

    Local $prevCastle = $g_CastlingRights
    Local $prevEP = $g_EnPassant
    Local $prevHalf = $g_HalfmoveClock
    Local $prevFull = $g_FullmoveNumber
    Local $prevHashHi = $g_ZobristHashHi
    Local $prevHashLo = $g_ZobristHashLo
    Local $prevEPFile = $g_ZobristEPFileActive
    Local $prevWK = $g_WhiteKingSquare
    Local $prevBK = $g_BlackKingSquare

    ; Remove old position components that can change.
    If $g_ZobristEPFileActive <> -1 Then _Core_HashXorPair($g_ZobristEPFileHi[$g_ZobristEPFileActive], $g_ZobristEPFileLo[$g_ZobristEPFileActive])
    _Core_HashAddPiece($piece, $from)

    Local $captured = $g_Board[$to]
    Local $capturedSquare = $to
    If BitAND($flags, $MOVE_FLAG_EN_PASSANT) Then
        $capturedSquare = $white ? $to - 8 : $to + 8
        $captured = $g_Board[$capturedSquare]
        If $captured <> $PIECE_EMPTY Then _Core_HashAddPiece($captured, $capturedSquare)
        $g_Board[$capturedSquare] = $PIECE_EMPTY
    ElseIf $captured <> $PIECE_EMPTY Then
        _Core_HashAddPiece($captured, $to)
    EndIf

    $g_Board[$from] = $PIECE_EMPTY

    Local $placed = $piece
    If BitAND($flags, $MOVE_FLAG_PROMOTION) Then
        Switch $promo
            Case $PIECE_WHITE_QUEEN
                $placed = $white ? $PIECE_WHITE_QUEEN : $PIECE_BLACK_QUEEN
            Case $PIECE_WHITE_ROOK
                $placed = $white ? $PIECE_WHITE_ROOK : $PIECE_BLACK_ROOK
            Case $PIECE_WHITE_BISHOP
                $placed = $white ? $PIECE_WHITE_BISHOP : $PIECE_BLACK_BISHOP
            Case $PIECE_WHITE_KNIGHT
                $placed = $white ? $PIECE_WHITE_KNIGHT : $PIECE_BLACK_KNIGHT
        EndSwitch
    EndIf
    $g_Board[$to] = $placed
    _Core_HashAddPiece($placed, $to)

    ; Castling rook move.
    If BitAND($flags, $MOVE_FLAG_CASTLING) Then
        Switch $to
            Case 6
                $g_Board[5] = $g_Board[7]
                $g_Board[7] = $PIECE_EMPTY
                _Core_HashAddPiece($PIECE_WHITE_ROOK, 7)
                _Core_HashAddPiece($PIECE_WHITE_ROOK, 5)
            Case 2
                $g_Board[3] = $g_Board[0]
                $g_Board[0] = $PIECE_EMPTY
                _Core_HashAddPiece($PIECE_WHITE_ROOK, 0)
                _Core_HashAddPiece($PIECE_WHITE_ROOK, 3)
            Case 62
                $g_Board[61] = $g_Board[63]
                $g_Board[63] = $PIECE_EMPTY
                _Core_HashAddPiece($PIECE_BLACK_ROOK, 63)
                _Core_HashAddPiece($PIECE_BLACK_ROOK, 61)
            Case 58
                $g_Board[59] = $g_Board[56]
                $g_Board[56] = $PIECE_EMPTY
                _Core_HashAddPiece($PIECE_BLACK_ROOK, 56)
                _Core_HashAddPiece($PIECE_BLACK_ROOK, 59)
        EndSwitch
    EndIf

    ; Incremental king cache.
    If $piece = $PIECE_WHITE_KING Then
        $g_WhiteKingSquare = $to
    ElseIf $piece = $PIECE_BLACK_KING Then
        $g_BlackKingSquare = $to
    EndIf

    Local $newCastle = $prevCastle
    _ChessCore_UpdateCastlingRightsOnMove($newCastle, $piece, $from, $to, $captured)
    If $newCastle <> $prevCastle Then
        _Core_HashXorPair($g_ZobristCastleHi[$prevCastle], $g_ZobristCastleLo[$prevCastle])
        _Core_HashXorPair($g_ZobristCastleHi[$newCastle], $g_ZobristCastleLo[$newCastle])
    EndIf

    Local $newHalf = $prevHalf + 1
    If _ChessCore_IsPawn($piece) Or $captured <> $PIECE_EMPTY Then $newHalf = 0
    Local $newFull = $prevFull
    If $side = 'b' Then $newFull += 1

    Local $newEP = -1
    If BitAND($flags, $MOVE_FLAG_DOUBLE_PAWN) Then $newEP = $white ? $from + 8 : $from - 8

    $g_CastlingRights = $newCastle
    $g_HalfmoveClock = $newHalf
    $g_FullmoveNumber = $newFull
    $g_EnPassant = $newEP
    $g_SideToMove = $white ? 'b' : 'w'
    _Core_HashXorPair($g_ZobristSideHi, $g_ZobristSideLo)

    $g_ZobristEPFileActive = -1
    If $newEP >= 0 Then
        Local $normalizedFile = _Core_NormalizedEPFile()
        If $normalizedFile <> -1 Then
            _Core_HashXorPair($g_ZobristEPFileHi[$normalizedFile], $g_ZobristEPFileLo[$normalizedFile])
            $g_ZobristEPFileActive = $normalizedFile
        EndIf
    EndIf

    _Core_StoreMoveState($iMove, $captured, $prevCastle, $prevEP, $prevHalf, $prevFull, $prevHashHi, $prevHashLo, $prevEPFile, $prevWK, $prevBK)
    Return 1
EndFunc

Func Core_UnmakeMove()
    If $g_MoveStackCount <= 0 Then Return SetError(1, 0, 0)
    $g_MoveStackCount -= 1
    Local $i = $g_MoveStackCount
    Local $move = $g_MoveStackMove[$i]
    Local $from = _Core_MoveFrom($move)
    Local $to = _Core_MoveTo($move)
    Local $flags = _Core_MoveFlags($move)
    Local $captured = $g_MoveStackCaptured[$i]
    Local $sideBefore = _ChessCore_OppositeSide($g_SideToMove)
    Local $white = ($sideBefore = 'w')

    ; Restore board squares from the move itself and saved captured piece.
    Local $origPiece
    If BitAND($flags, $MOVE_FLAG_PROMOTION) Then
        $origPiece = $white ? $PIECE_WHITE_PAWN : $PIECE_BLACK_PAWN
    Else
        $origPiece = $g_Board[$to]
    EndIf

    $g_Board[$from] = $origPiece
    $g_Board[$to] = $PIECE_EMPTY

    If BitAND($flags, $MOVE_FLAG_EN_PASSANT) Then
        Local $victimSquare = $white ? $to - 8 : $to + 8
        $g_Board[$victimSquare] = $captured
    ElseIf $captured <> $PIECE_EMPTY Then
        $g_Board[$to] = $captured
    EndIf

    If BitAND($flags, $MOVE_FLAG_CASTLING) Then
        Switch $to
            Case 6
                $g_Board[7] = $g_Board[5]
                $g_Board[5] = $PIECE_EMPTY
            Case 2
                $g_Board[0] = $g_Board[3]
                $g_Board[3] = $PIECE_EMPTY
            Case 62
                $g_Board[63] = $g_Board[61]
                $g_Board[61] = $PIECE_EMPTY
            Case 58
                $g_Board[56] = $g_Board[59]
                $g_Board[59] = $PIECE_EMPTY
        EndSwitch
    EndIf

    $g_CastlingRights = $g_MoveStackCastling[$i]
    $g_EnPassant = $g_MoveStackEP[$i]
    $g_HalfmoveClock = $g_MoveStackHalfmove[$i]
    $g_FullmoveNumber = $g_MoveStackFullmove[$i]
    $g_ZobristHashHi = $g_MoveStackHashHi[$i]
    $g_ZobristHashLo = $g_MoveStackHashLo[$i]
    $g_ZobristEPFileActive = $g_MoveStackEPHashFile[$i]
    $g_WhiteKingSquare = $g_MoveStackWhiteKing[$i]
    $g_BlackKingSquare = $g_MoveStackBlackKing[$i]
    $g_SideToMove = $sideBefore
    Return 1
EndFunc

; ============================== Legal Moves ====================================
Func Core_GenerateLegalMoves()
    Local $pseudo = _Core_GeneratePseudoMovesPacked()
    Local $n = UBound($pseudo)
    Local $legal[$n]
    Local $count = 0
    Local $side = $g_SideToMove
    Local $opponent = _ChessCore_OppositeSide($side)

    For $i = 0 To $n - 1
        Core_MakeMove($pseudo[$i])
        Local $kingSquare = ($side = 'w') ? $g_WhiteKingSquare : $g_BlackKingSquare
        If Not _ChessCore_IsSquareAttackedOnBoard($g_Board, $kingSquare, $opponent) Then
            $legal[$count] = $pseudo[$i]
            $count += 1
        EndIf
        Core_UnmakeMove()
    Next

    ReDim $legal[$count]
    Return $legal
EndFunc

Func _Core_HasAnyLegalMove()
    Local $pseudo = _Core_GeneratePseudoMovesPacked()
    Local $side = $g_SideToMove
    Local $opponent = _ChessCore_OppositeSide($side)
    For $i = 0 To UBound($pseudo) - 1
        Core_MakeMove($pseudo[$i])
        Local $kingSquare = ($side = 'w') ? $g_WhiteKingSquare : $g_BlackKingSquare
        Local $legal = Not _ChessCore_IsSquareAttackedOnBoard($g_Board, $kingSquare, $opponent)
        Core_UnmakeMove()
        If $legal Then Return True
    Next
    Return False
EndFunc

; Phase-9 public API compatibility: return the same UCI-string contract.
Func ChessCore_GenerateLegalMoves()
    Return Core_GenerateLegalMovesUCI()
EndFunc

Func Core_GenerateLegalMovesUCI()
    Local $packed = Core_GenerateLegalMoves()
    Local $n = UBound($packed)
    If $n = 0 Then
        Local $empty[1] = ['']
        Return $empty
    EndIf
    Local $moves[$n]
    For $i = 0 To $n - 1
        $moves[$i] = Core_MoveToUCI($packed[$i])
    Next
    Return $moves
EndFunc

Func _ChessCore_IsMoveLegalParsed($iFrom, $iTo, $iPromo)
    Local $legal = Core_GenerateLegalMoves()
    For $i = 0 To UBound($legal) - 1
        If _Core_MoveFrom($legal[$i]) = $iFrom And _Core_MoveTo($legal[$i]) = $iTo And _Core_MovePromo($legal[$i]) = $iPromo Then Return True
    Next
    Return False
EndFunc

Func ChessCore_IsLegalMove($sUCI)
    Local $from, $to, $promo
    If Not ChessCore_ParseUCI($sUCI, $from, $to, $promo) Then Return False
    Return _ChessCore_IsMoveLegalParsed($from, $to, $promo)
EndFunc

Func ChessCore_IsLegalMoveEx($iFrom, $iTo, $iPromo = $PIECE_EMPTY)
    Return _ChessCore_IsMoveLegalParsed($iFrom, $iTo, $iPromo)
EndFunc

; ============================== Public Game Push/Pop ===========================
Func _Core_FindLegalPackedMove($iFrom, $iTo, $iPromo)
    Local $legal = Core_GenerateLegalMoves()
    For $i = 0 To UBound($legal) - 1
        If _Core_MoveFrom($legal[$i]) = $iFrom And _Core_MoveTo($legal[$i]) = $iTo And _Core_MovePromo($legal[$i]) = $iPromo Then Return $legal[$i]
    Next
    Return -1
EndFunc

Func ChessCore_PushMoveEx($iFrom, $iTo, $iPromo = $PIECE_EMPTY)
    Local $move = _Core_FindLegalPackedMove($iFrom, $iTo, $iPromo)
    If $move < 0 Then Return SetError(1, 0, 0)
    Core_MakeMove($move)
    _Core_GameHistoryPushMove($move)
    Return 1
EndFunc

Func ChessCore_PushMove($sUCI)
    Local $from, $to, $promo
    If Not ChessCore_ParseUCI($sUCI, $from, $to, $promo) Then Return SetError(1, 0, 0)
    Return ChessCore_PushMoveEx($from, $to, $promo)
EndFunc

Func ChessCore_PopMove()
    If ChessCore_GetMoveHistoryCount() <= 0 Then Return SetError(1, 0, 0)
    If Not Core_UnmakeMove() Then Return SetError(2, 0, 0)
    _Core_GameHistoryPop()
    Return 1
EndFunc

; ============================== Status =========================================
Func ChessCore_IsCheck()
    Local $kingSquare = ($g_SideToMove = 'w') ? $g_WhiteKingSquare : $g_BlackKingSquare
    If $kingSquare < 0 Then Return SetError(1, 0, False)
    Return _ChessCore_IsSquareAttackedOnBoard($g_Board, $kingSquare, _ChessCore_OppositeSide($g_SideToMove))
EndFunc

Func ChessCore_IsCheckmate()
    If Not ChessCore_IsCheck() Then Return False
    Return Not _Core_HasAnyLegalMove()
EndFunc

Func ChessCore_IsStalemate()
    If ChessCore_IsCheck() Then Return False
    Return Not _Core_HasAnyLegalMove()
EndFunc

Func _ChessCore_HasInsufficientMaterial()
    Local $minor = 0, $bishops = 0
    Local $bishopSquares[32]
    For $sq = 0 To 63
        Local $p = $g_Board[$sq]
        If $p = $PIECE_EMPTY Or _ChessCore_IsKing($p) Then ContinueLoop
        Switch $p
            Case $PIECE_WHITE_PAWN, $PIECE_BLACK_PAWN, $PIECE_WHITE_ROOK, $PIECE_BLACK_ROOK, $PIECE_WHITE_QUEEN, $PIECE_BLACK_QUEEN
                Return False
            Case $PIECE_WHITE_KNIGHT, $PIECE_BLACK_KNIGHT
                $minor += 1
            Case $PIECE_WHITE_BISHOP, $PIECE_BLACK_BISHOP
                $minor += 1
                $bishopSquares[$bishops] = $sq
                $bishops += 1
        EndSwitch
    Next
    If $minor = 0 Then Return True
    If $minor = 1 Then Return True
    If $minor = 2 And $bishops = 2 Then
        Local $f1, $r1, $f2, $r2
        ChessCore_IndexToFileRank($bishopSquares[0], $f1, $r1)
        ChessCore_IndexToFileRank($bishopSquares[1], $f2, $r2)
        If Mod($f1 + $r1, 2) = Mod($f2 + $r2, 2) Then Return True
    EndIf
    Return False
EndFunc

Func ChessCore_IsDraw()
    Local $inCheck = ChessCore_IsCheck()
    Local $hasLegalMove = _Core_HasAnyLegalMove()
    If Not $hasLegalMove Then Return Not $inCheck
    If $g_HalfmoveClock >= 100 Then Return True
    If _ChessCore_HasInsufficientMaterial() Then Return True
    Return ChessCore_CountRepetitions() >= 3
EndFunc

Func ChessCore_GetGameStatus()
    Local $inCheck = ChessCore_IsCheck()
    Local $hasLegalMove = _Core_HasAnyLegalMove()
    If Not $hasLegalMove Then
        If $inCheck Then Return 'checkmate'
        Return 'stalemate'
    EndIf
    If $g_HalfmoveClock >= 100 Then Return 'draw_fifty'
    If _ChessCore_HasInsufficientMaterial() Then Return 'draw_insufficient'
    If ChessCore_CountRepetitions() >= 3 Then Return 'draw_repetition'
    If $inCheck Then Return 'check'
    Return 'normal'
EndFunc

Func ChessCore_GetOutcome()
    Local $status = ChessCore_GetGameStatus()
    Switch $status
        Case 'checkmate'
            Return ($g_SideToMove = 'w') ? 'black_win' : 'white_win'
        Case 'stalemate', 'draw_fifty', 'draw_insufficient', 'draw_repetition'
            Return 'draw'
    EndSwitch
    Return 'none'
EndFunc

Func ChessCore_ValidateCurrentPosition()
    Return ChessCore_ValidateFEN(ChessCore_GetFEN())
EndFunc

; ============================== Initialization =================================
Func ChessCore_NewGame()
    Return ChessCore_SetFEN('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1')
EndFunc

Func ChessCore_Init()
    If Not $g_ZobristReady Then _Core_InitZobrist()
    Return ChessCore_NewGame()
EndFunc

Func ChessCore_Reset()
    Return ChessCore_NewGame()
EndFunc

; ============================== Perft ==========================================
Func ChessCore_Perft($iDepth, $bFast = True)
    If $iDepth < 0 Or Int($iDepth) <> $iDepth Then Return SetError(1, 0, -1)
    If $iDepth = 0 Then Return 1

    Local $legal = Core_GenerateLegalMoves()
    Local $n = UBound($legal)
    If $n = 0 Then Return 0
    If $iDepth = 1 Then Return $n

    Local $nodes = 0
    For $i = 0 To $n - 1
        Core_MakeMove($legal[$i])
        $nodes += ChessCore_Perft($iDepth - 1, $bFast)
        Core_UnmakeMove()
    Next
    Return $nodes
EndFunc

Func _ChessCore_PerftFast($iDepth)
    Return ChessCore_Perft($iDepth, True)
EndFunc

Func ChessCore_PerftDivide($iDepth)
    If $iDepth < 1 Or Int($iDepth) <> $iDepth Then Return SetError(1, 0, 0)
    Local $legal = Core_GenerateLegalMoves()
    Local $n = UBound($legal)
    Local $result[1][2]
    If $n = 0 Then
        $result[0][0] = ''
        $result[0][1] = 0
        Return $result
    EndIf
    ReDim $result[$n][2]
    For $i = 0 To $n - 1
        $result[$i][0] = Core_MoveToUCI($legal[$i])
        Core_MakeMove($legal[$i])
        $result[$i][1] = ChessCore_Perft($iDepth - 1, True)
        Core_UnmakeMove()
    Next
    Return $result
EndFunc

; ============================== Internal Compatibility Names ===================
; Kept for callers that used Phase-9 private helpers. They now route to the
; unified implementation instead of creating a second state model.
Func _ChessCore_MoveArrayCount(Const ByRef $aMoves)
    Return ChessCore_GetMoveCount($aMoves)
EndFunc

Func _ChessCore_NormalizedEPSquare()
    If $g_EnPassant < 0 Then Return -1
    Local $f = _Core_NormalizedEPFile()
    If $f < 0 Then Return -1
    Return Int($g_EnPassant / 8) * 8 + $f
EndFunc

Func _ChessCore_GetPositionKey()
    Return ChessCore_GetPositionHash()
EndFunc

Func _ChessCore_AddPositionKey()
    ; Position identity is maintained incrementally. The old explicit key array
    ; is intentionally gone; committed repetition history stores hash pairs.
    Return 1
EndFunc

Func _ChessCore_RemovePositionKey()
    Return 1
EndFunc

Func _ChessCore_RebuildHistory()
    _ChessCore_ClearMoveStack()
    _ChessCore_ClearCommittedHistory()
    _Core_RebuildPositionHash()
    _Core_GameHistoryPushHash()
EndFunc

; One-time table initialization. The board itself is still initialized by Init.
_Core_InitZobrist()
