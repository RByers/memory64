(* Version *)

let version = 0x0cl


(* Encoding stream *)

type stream =
{
  buf : Buffer.t;
  patches : (int * char) list ref
}

let stream () = {buf = Buffer.create 8192; patches = ref []}
let pos s = Buffer.length s.buf
let put s b = Buffer.add_char s.buf b
let put_string s bs = Buffer.add_string s.buf bs
let patch s pos b = s.patches := (pos, b) :: !(s.patches)

let to_string s =
  let bs = Buffer.to_bytes s.buf in
  List.iter (fun (pos, b) -> Bytes.set bs pos b) !(s.patches);
  Bytes.to_string bs


(* Encoding *)

let encode m =
  let s = stream () in

  let module E = struct
    (* Generic values *)

    let u8 i = put s (Char.chr (i land 0xff))
    let u16 i = u8 (i land 0xff); u8 (i lsr 8)
    let u32 i =
      Int32.(u16 (to_int (logand i 0xffffl));
             u16 (to_int (shift_right i 16)))
    let u64 i =
      Int64.(u32 (to_int32 (logand i 0xffffffffL));
             u32 (to_int32 (shift_right i 32)))

    let rec vu64 i =
      let b = Int64.(to_int (logand i 0x7fL)) in
      if i < 128L then u8 b
      else (u8 (b lor 0x80); vu64 (Int64.shift_right i 7))

    let rec vs64 i =
      let b = Int64.(to_int (logand i 0x7fL)) in
      if -64L <= i && i < 64L then u8 b
      else (u8 (b lor 0x80); vs64 (Int64.shift_right i 7))

    let vu32 i = vu64 (Int64.of_int32 i)
    let vs32 i = vs64 (Int64.of_int32 i)
    let vu i = vu64 (Int64.of_int i)
    let f32 x = u32 (F32.to_bits x)
    let f64 x = u64 (F64.to_bits x)

    let bool b = u8 (if b then 1 else 0)
    let string bs = vu (String.length bs); put_string s bs
    let list f xs = List.iter f xs
    let opt f xo = Lib.Option.app f xo
    let vec f xs = vu (List.length xs); list f xs
    let vec1 f xo = bool (xo <> None); opt f xo

    let gap () = let p = pos s in u32 0l; p
    let patch_gap p n =
      assert (n <= 0x0fff_ffff); (* Strings cannot excess 2G anyway *)
      let lsb i = Char.chr (i land 0xff) in
      patch s p (lsb (n lor 0x80));
      patch s (p + 1) (lsb ((n lsr 7) lor 0x80));
      patch s (p + 2) (lsb ((n lsr 14) lor 0x80));
      patch s (p + 3) (lsb (n lsr 21))

    (* Types *)

    open Types

    let value_type = function
      | I32Type -> u8 0x01
      | I64Type -> u8 0x02
      | F32Type -> u8 0x03
      | F64Type -> u8 0x04

    let elem_type = function
      | AnyFuncType -> u8 0x20

    let expr_type t = vec1 value_type t

    let func_type = function
      | FuncType (ins, out) -> u8 0x40; vec value_type ins; vec value_type out

    (* Expressions *)

    open Source
    open Ast
    open Values
    open Memory

    let op n = u8 n
    let memop {align; offset; _} = vu align; vu64 offset  (*TODO: to be resolved*)

    let var x = vu x.it
    let var32 x = vu32 (Int32.of_int x.it)

    let rec expr e =
      match e.it with
      | Unreachable -> op 0x00
      | Block es -> op 0x01; list expr es; op 0x0f
      | Loop es -> op 0x02; list expr es; op 0x0f
      | If (es1, es2) ->
        op 0x03; list expr es1;
        if es2 <> [] then op 0x04;
        list expr es2; op 0x0f
      | Select -> op 0x05
      | Br (n, x) -> op 0x06; vu n; var x
      | BrIf (n, x) -> op 0x07; vu n; var x
      | BrTable (n, xs, x) -> op 0x08; vu n; vec var32 xs; var32 x
      | Return -> op 0x09
      | Nop -> op 0x0a
      | Drop -> op 0x0b

      | Const {it = I32 c} -> op 0x10; vs32 c
      | Const {it = I64 c} -> op 0x11; vs64 c
      | Const {it = F32 c} -> op 0x12; f32 c
      | Const {it = F64 c} -> op 0x13; f64 c

      | GetLocal x -> op 0x14; var x
      | SetLocal x -> op 0x15; var x
      | TeeLocal x -> op 0x19; var x
      | GetGlobal x -> op 0xbb; var x
      | SetGlobal x -> op 0xbc; var x

      | Call x -> op 0x16; var x
      | CallIndirect x -> op 0x17; var x
      | CallImport x -> op 0x18; var x

      | Load ({ty = I32Type; sz = None; _} as mo) -> op 0x2a; memop mo
      | Load ({ty = I64Type; sz = None; _} as mo) -> op 0x2b; memop mo
      | Load ({ty = F32Type; sz = None; _} as mo) -> op 0x2c; memop mo
      | Load ({ty = F64Type; sz = None; _} as mo) -> op 0x2d; memop mo
      | Load ({ty = I32Type; sz = Some (Mem8, SX); _} as mo) ->
        op 0x20; memop mo
      | Load ({ty = I32Type; sz = Some (Mem8, ZX); _} as mo) ->
        op 0x21; memop mo
      | Load ({ty = I32Type; sz = Some (Mem16, SX); _} as mo) ->
        op 0x22; memop mo
      | Load ({ty = I32Type; sz = Some (Mem16, ZX); _} as mo) ->
        op 0x23; memop mo
      | Load {ty = I32Type; sz = Some (Mem32, _); _} ->
        assert false
      | Load ({ty = I64Type; sz = Some (Mem8, SX); _} as mo) ->
        op 0x24; memop mo
      | Load ({ty = I64Type; sz = Some (Mem8, ZX); _} as mo) ->
        op 0x25; memop mo
      | Load ({ty = I64Type; sz = Some (Mem16, SX); _} as mo) ->
        op 0x26; memop mo
      | Load ({ty = I64Type; sz = Some (Mem16, ZX); _} as mo) ->
        op 0x27; memop mo
      | Load ({ty = I64Type; sz = Some (Mem32, SX); _} as mo) ->
        op 0x28; memop mo
      | Load ({ty = I64Type; sz = Some (Mem32, ZX); _} as mo) ->
        op 0x29; memop mo
      | Load {ty = F32Type | F64Type; sz = Some _; _} ->
        assert false

      | Store ({ty = I32Type; sz = None; _} as mo) -> op 0x33; memop mo
      | Store ({ty = I64Type; sz = None; _} as mo) -> op 0x34; memop mo
      | Store ({ty = F32Type; sz = None; _} as mo) -> op 0x35; memop mo
      | Store ({ty = F64Type; sz = None; _} as mo) -> op 0x36; memop mo
      | Store ({ty = I32Type; sz = Some Mem8; _} as mo) -> op 0x2e; memop mo
      | Store ({ty = I32Type; sz = Some Mem16; _} as mo) -> op 0x2f; memop mo
      | Store {ty = I32Type; sz = Some Mem32; _} -> assert false
      | Store ({ty = I64Type; sz = Some Mem8; _} as mo) -> op 0x30; memop mo
      | Store ({ty = I64Type; sz = Some Mem16; _} as mo) -> op 0x31; memop mo
      | Store ({ty = I64Type; sz = Some Mem32; _} as mo) -> op 0x32; memop mo
      | Store {ty = F32Type | F64Type; sz = Some _; _} -> assert false

      | GrowMemory -> op 0x39
      | CurrentMemory -> op 0x3b

      | Unary (I32 I32Op.Clz) -> op 0x57
      | Unary (I32 I32Op.Ctz) -> op 0x58
      | Unary (I32 I32Op.Popcnt) -> op 0x59

      | Unary (I64 I64Op.Clz) -> op 0x72
      | Unary (I64 I64Op.Ctz) -> op 0x73
      | Unary (I64 I64Op.Popcnt) -> op 0x74

      | Unary (F32 F32Op.Neg) -> op 0x7c
      | Unary (F32 F32Op.Abs) -> op 0x7b
      | Unary (F32 F32Op.Ceil) -> op 0x7e
      | Unary (F32 F32Op.Floor) -> op 0x7f
      | Unary (F32 F32Op.Trunc) -> op 0x80
      | Unary (F32 F32Op.Nearest) -> op 0x81
      | Unary (F32 F32Op.Sqrt) -> op 0x82

      | Unary (F64 F64Op.Neg) -> op 0x90
      | Unary (F64 F64Op.Abs) -> op 0x8f
      | Unary (F64 F64Op.Ceil) -> op 0x92
      | Unary (F64 F64Op.Floor) -> op 0x93
      | Unary (F64 F64Op.Trunc) -> op 0x94
      | Unary (F64 F64Op.Nearest) -> op 0x95
      | Unary (F64 F64Op.Sqrt) -> op 0x96

      | Binary (I32 I32Op.Add) -> op 0x40
      | Binary (I32 I32Op.Sub) -> op 0x41
      | Binary (I32 I32Op.Mul) -> op 0x42
      | Binary (I32 I32Op.DivS) -> op 0x43
      | Binary (I32 I32Op.DivU) -> op 0x44
      | Binary (I32 I32Op.RemS) -> op 0x45
      | Binary (I32 I32Op.RemU) -> op 0x46
      | Binary (I32 I32Op.And) -> op 0x47
      | Binary (I32 I32Op.Or) -> op 0x48
      | Binary (I32 I32Op.Xor) -> op 0x49
      | Binary (I32 I32Op.Shl) -> op 0x4a
      | Binary (I32 I32Op.ShrS) -> op 0x4c
      | Binary (I32 I32Op.ShrU) -> op 0x4b
      | Binary (I32 I32Op.Rotl) -> op 0xb6
      | Binary (I32 I32Op.Rotr) -> op 0xb7

      | Binary (I64 I64Op.Add) -> op 0x5b
      | Binary (I64 I64Op.Sub) -> op 0x5c
      | Binary (I64 I64Op.Mul) -> op 0x5d
      | Binary (I64 I64Op.DivS) -> op 0x5e
      | Binary (I64 I64Op.DivU) -> op 0x5f
      | Binary (I64 I64Op.RemS) -> op 0x60
      | Binary (I64 I64Op.RemU) -> op 0x61
      | Binary (I64 I64Op.And) -> op 0x62
      | Binary (I64 I64Op.Or) -> op 0x63
      | Binary (I64 I64Op.Xor) -> op 0x64
      | Binary (I64 I64Op.Shl) -> op 0x65
      | Binary (I64 I64Op.ShrS) -> op 0x67
      | Binary (I64 I64Op.ShrU) -> op 0x66
      | Binary (I64 I64Op.Rotl) -> op 0xb8
      | Binary (I64 I64Op.Rotr) -> op 0xb9

      | Binary (F32 F32Op.Add) -> op 0x75
      | Binary (F32 F32Op.Sub) -> op 0x76
      | Binary (F32 F32Op.Mul) -> op 0x77
      | Binary (F32 F32Op.Div) -> op 0x78
      | Binary (F32 F32Op.Min) -> op 0x79
      | Binary (F32 F32Op.Max) -> op 0x7a
      | Binary (F32 F32Op.CopySign) -> op 0x7d

      | Binary (F64 F64Op.Add) -> op 0x89
      | Binary (F64 F64Op.Sub) -> op 0x8a
      | Binary (F64 F64Op.Mul) -> op 0x8b
      | Binary (F64 F64Op.Div) -> op 0x8c
      | Binary (F64 F64Op.Min) -> op 0x8d
      | Binary (F64 F64Op.Max) -> op 0x8e
      | Binary (F64 F64Op.CopySign) -> op 0x91

      | Test (I32 I32Op.Eqz) -> op 0x5a
      | Test (I64 I64Op.Eqz) -> op 0xba
      | Test (F32 _) -> assert false
      | Test (F64 _) -> assert false

      | Compare (I32 I32Op.Eq) -> op 0x4d
      | Compare (I32 I32Op.Ne) -> op 0x4e
      | Compare (I32 I32Op.LtS) -> op 0x4f
      | Compare (I32 I32Op.LtU) -> op 0x51
      | Compare (I32 I32Op.LeS) -> op 0x50
      | Compare (I32 I32Op.LeU) -> op 0x52
      | Compare (I32 I32Op.GtS) -> op 0x53
      | Compare (I32 I32Op.GtU) -> op 0x55
      | Compare (I32 I32Op.GeS) -> op 0x54
      | Compare (I32 I32Op.GeU) -> op 0x56

      | Compare (I64 I64Op.Eq) -> op 0x68
      | Compare (I64 I64Op.Ne) -> op 0x69
      | Compare (I64 I64Op.LtS) -> op 0x6a
      | Compare (I64 I64Op.LtU) -> op 0x6c
      | Compare (I64 I64Op.LeS) -> op 0x6b
      | Compare (I64 I64Op.LeU) -> op 0x6d
      | Compare (I64 I64Op.GtS) -> op 0x6e
      | Compare (I64 I64Op.GtU) -> op 0x70
      | Compare (I64 I64Op.GeS) -> op 0x6f
      | Compare (I64 I64Op.GeU) -> op 0x71

      | Compare (F32 F32Op.Eq) -> op 0x83
      | Compare (F32 F32Op.Ne) -> op 0x84
      | Compare (F32 F32Op.Lt) -> op 0x85
      | Compare (F32 F32Op.Le) -> op 0x86
      | Compare (F32 F32Op.Gt) -> op 0x87
      | Compare (F32 F32Op.Ge) -> op 0x88

      | Compare (F64 F64Op.Eq) -> op 0x97
      | Compare (F64 F64Op.Ne) -> op 0x98
      | Compare (F64 F64Op.Lt) -> op 0x99
      | Compare (F64 F64Op.Le) -> op 0x9a
      | Compare (F64 F64Op.Gt) -> op 0x9b
      | Compare (F64 F64Op.Ge) -> op 0x9c

      | Convert (I32 I32Op.TruncSF32) -> op 0x9d
      | Convert (I32 I32Op.TruncSF64) -> op 0x9e
      | Convert (I32 I32Op.TruncUF32) -> op 0x9f
      | Convert (I32 I32Op.TruncUF64) -> op 0xa0
      | Convert (I32 I32Op.WrapI64) -> op 0xa1
      | Convert (I32 I32Op.ExtendSI32) -> assert false
      | Convert (I32 I32Op.ExtendUI32) -> assert false
      | Convert (I32 I32Op.ReinterpretFloat) -> op 0xb4

      | Convert (I64 I64Op.TruncSF32) -> op 0xa2
      | Convert (I64 I64Op.TruncSF64) -> op 0xa3
      | Convert (I64 I64Op.TruncUF32) -> op 0xa4
      | Convert (I64 I64Op.TruncUF64) -> op 0xa5
      | Convert (I64 I64Op.WrapI64) -> assert false
      | Convert (I64 I64Op.ExtendSI32) -> op 0xa6
      | Convert (I64 I64Op.ExtendUI32) -> op 0xa7
      | Convert (I64 I64Op.ReinterpretFloat) -> op 0xb5

      | Convert (F32 F32Op.ConvertSI32) -> op 0xa8
      | Convert (F32 F32Op.ConvertUI32) -> op 0xa9
      | Convert (F32 F32Op.ConvertSI64) -> op 0xaa
      | Convert (F32 F32Op.ConvertUI64) -> op 0xab
      | Convert (F32 F32Op.PromoteF32) -> assert false
      | Convert (F32 F32Op.DemoteF64) -> op 0xac
      | Convert (F32 F32Op.ReinterpretInt) -> op 0xad

      | Convert (F64 F64Op.ConvertSI32) -> op 0xae
      | Convert (F64 F64Op.ConvertUI32) -> op 0xaf
      | Convert (F64 F64Op.ConvertSI64) -> op 0xb0
      | Convert (F64 F64Op.ConvertUI64) -> op 0xb1
      | Convert (F64 F64Op.PromoteF32) -> op 0xb2
      | Convert (F64 F64Op.DemoteF64) -> assert false
      | Convert (F64 F64Op.ReinterpretInt) -> op 0xb3

      | Trapping _ | Label _ | Local _ -> assert false

    let const c =
      list expr c.it; op 0x0f


    (* Sections *)

    let section id f x needed =
      if needed then begin
        string id;
        let g = gap () in
        let p = pos s in
        f x;
        patch_gap g (pos s - p)
      end

    (* Type section *)
    let type_section ts =
      section "type" (vec func_type) ts (ts <> [])

    (* Import section *)
    let import imp =
      let {itype; module_name; func_name} = imp.it in
      var itype; string module_name; string func_name

    let import_section imps =
      section "import" (vec import) imps (imps <> [])

    (* Function section *)
    let func f = var f.it.ftype

    let func_section fs =
      section "function" (vec func) fs (fs <> [])

    (* Table section *)
    let limits vu lim =
      let {min; max} = lim.it in
      bool (max <> None); vu min; opt vu max

    let table tab =
      let {etype; tlimits} = tab.it in
      elem_type etype; limits vu32 tlimits

    let table_section tabo =
      section "table" (opt table) tabo (tabo <> None)

    (* Memory section *)
    let memory mem =
      let {mlimits} = mem.it in
      limits vu32 mlimits

    let memory_section memo =
      section "memory" (opt memory) memo (memo <> None)

    (* Global section *)
    let global g =
      let {gtype; value} = g.it in
      value_type gtype; const value

    let global_section gs =
      section "global" (vec global) gs (gs <> [])

    (* Export section *)
    let export exp =
      let {Ast.name; kind} = exp.it in
      (match kind with
      | `Func x -> var x
      | `Memory -> () (*TODO: pending resolution*)
      ); string name

    let export_section exps =
      (*TODO: pending resolution*)
      let exps = List.filter (fun exp -> exp.it.kind <> `Memory) exps in
      section "export" (vec export) exps (exps <> [])

    (* Start section *)
    let start_section xo =
      section "start" (opt var) xo (xo <> None)

    (* Code section *)
    let compress ts =
      let combine t = function
        | (t', n) :: ts when t = t' -> (t, n + 1) :: ts
        | ts -> (t, 1) :: ts
      in List.fold_right combine ts []

    let local (t, n) = vu n; value_type t

    let code f =
      let {locals; body; _} = f.it in
      vec local (compress locals);
      let g = gap () in
      let p = pos s in
      list expr body;
      patch_gap g (pos s - p)

    let code_section fs =
      section "code" (vec code) fs (fs <> [])

    (* Element section *)
    let segment dat seg =
      let {offset; init} = seg.it in
      const offset; dat init

    let table_segment seg =
      segment (vec var) seg

    let elem_section elems =
      section "element" (vec table_segment) elems (elems <> [])

    (* Data section *)
    let memory_segment seg =
      segment string seg

    let data_section data =
      section "data" (vec memory_segment) data (data <> [])

    (* Module *)

    let module_ m =
      u32 0x6d736100l;
      u32 version;
      type_section m.it.types;
      import_section m.it.imports;
      func_section m.it.funcs;
      table_section m.it.table;
      memory_section m.it.memory;
      global_section m.it.globals;
      export_section m.it.exports;
      start_section m.it.start;
      code_section m.it.funcs;
      elem_section m.it.elems;
      data_section m.it.data
  end
  in E.module_ m; to_string s
