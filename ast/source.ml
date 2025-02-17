(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open Pyre

type mode =
  | Default
  | DefaultButDontCheck of int list
  | Declare
  | Strict
  | Unsafe
  | Infer
  | PlaceholderStub
[@@deriving compare, eq, show, sexp, hash]

module Metadata = struct
  type t = {
    autogenerated: bool;
    debug: bool;
    local_mode: mode;
    ignore_lines: Ignore.t list;
    version: int;
    number_of_lines: int; [@hash.ignore]
    raw_hash: int; [@hash.ignore]
  }
  [@@deriving compare, eq, show, hash, sexp]

  let create_for_testing
      ?(autogenerated = false)
      ?(debug = true)
      ?(local_mode = Default)
      ?(ignore_lines = [])
      ?(version = 3)
      ?(raw_hash = -1)
      ?(number_of_lines = 0)
      ()
    =
    { autogenerated; debug; local_mode; ignore_lines; number_of_lines; version; raw_hash }


  let signature_hash { autogenerated; debug; local_mode; version; _ } =
    [%hash: bool * bool * mode * int] (autogenerated, debug, local_mode, version)


  let declare_regex = Str.regexp "^[ \t]*# *pyre-ignore-all-errors *$"

  let default_with_suppress_regex =
    Str.regexp "^[ \t]*# *pyre-ignore-all-errors\\[\\([0-9]+, *\\)*\\([0-9]+\\)\\] *$"


  let ignore_code_regex = Str.regexp "pyre-\\(ignore\\|fixme\\)\\[\\([0-9, ]+\\)\\]"

  let ignore_location_regex = Str.regexp "\\(pyre-\\(ignore\\|fixme\\)\\|type: ignore\\)"

  let parse ~qualifier lines =
    let is_python_2_shebang line =
      String.is_prefix ~prefix:"#!" line && String.is_substring ~substring:"python2" line
    in
    let is_pyre_comment comment_substring line =
      String.is_prefix ~prefix:"#" line && String.is_substring ~substring:comment_substring line
    in
    let is_debug = is_pyre_comment "pyre-debug" in
    let is_strict = is_pyre_comment "pyre-strict" in
    let is_unsafe = is_pyre_comment "pyre-unsafe" in
    (* We do not fall back to declarative mode on a typo when attempting to only suppress certain
       errors. *)
    let is_declare line = Str.string_match declare_regex line 0 in
    let is_default_with_suppress line = Str.string_match default_with_suppress_regex line 0 in
    let is_placeholder_stub = is_pyre_comment "pyre-placeholder-stub" in
    let parse_ignore index line ignore_lines =
      let line_index = index + 1 in
      let create_ignore ~line ~kind =
        let codes =
          try
            Str.search_forward ignore_code_regex line 0 |> ignore;
            Str.matched_group 2 line
            |> Str.split (Str.regexp "[^0-9]+")
            |> List.map ~f:Int.of_string
          with
          | Not_found -> []
        in
        let location =
          let start_column = Str.search_forward ignore_location_regex line 0 in
          let end_column = String.length line in
          let start = { Location.line = line_index; column = start_column } in
          let stop = { Location.line = line_index; column = end_column } in
          { Location.path = qualifier; start; stop }
        in
        Ignore.create ~ignored_line:line_index ~codes ~location ~kind
      in
      let contains_outside_quotes ~substring line =
        let find_substring index characters =
          String.is_substring ~substring characters && index mod 2 = 0
        in
        String.split_on_chars ~on:['\"'; '\''] line |> List.existsi ~f:find_substring
      in
      let ignore_lines =
        let kind =
          if
            contains_outside_quotes ~substring:"pyre-ignore" line
            && not (contains_outside_quotes ~substring:"pyre-ignore-all-errors" line)
          then
            Some Ignore.PyreIgnore
          else if contains_outside_quotes ~substring:"pyre-fixme" line then
            Some Ignore.PyreFixme
          else if contains_outside_quotes ~substring:"type: ignore" line then
            Some Ignore.TypeIgnore
          else
            None
        in
        kind
        >>| (fun kind -> create_ignore ~line ~kind)
        >>| (fun data -> Int.Map.add_multi ~key:line_index ~data ignore_lines)
        |> Option.value ~default:ignore_lines
      in
      if String.is_prefix ~prefix:"#" (String.strip line) then
        (* Increment ignores applied to current line if it is a comment. *)
        match Int.Map.find ignore_lines line_index with
        | Some ignores -> (
            let ignore_lines = Int.Map.remove ignore_lines line_index in
            match Int.Map.find ignore_lines (line_index + 1) with
            | Some existing_ignores ->
                Int.Map.set
                  ~key:(line_index + 1)
                  ~data:(List.map ~f:Ignore.increment ignores @ existing_ignores)
                  ignore_lines
            | None ->
                Int.Map.set
                  ~key:(line_index + 1)
                  ~data:(List.map ~f:Ignore.increment ignores)
                  ignore_lines )
        | None -> ignore_lines
      else
        ignore_lines
    in
    let is_autogenerated line =
      String.is_substring ~substring:("@" ^ "generated") line
      || String.is_substring ~substring:("@" ^ "auto-generated") line
    in
    let collect index (version, debug, local_mode, ignore_lines, autogenerated) line =
      let local_mode =
        match local_mode with
        | Some _ -> local_mode
        | None ->
            if is_default_with_suppress line then
              let suppressed_codes =
                Str.global_substitute (Str.regexp "[^,0-9]+") (fun _ -> "") line
                |> String.split_on_chars ~on:[',']
                |> List.map ~f:int_of_string
              in
              Some (DefaultButDontCheck suppressed_codes)
            else if is_declare line then
              Some Declare
            else if is_strict line then
              Some Strict
            else if is_unsafe line then
              Some Unsafe
            else if is_placeholder_stub line then
              Some PlaceholderStub
            else
              None
      in
      let version =
        match version with
        | Some _ -> version
        | None -> if is_python_2_shebang line then Some 2 else None
      in
      ( version,
        debug || is_debug line,
        local_mode,
        parse_ignore index line ignore_lines,
        autogenerated || is_autogenerated line )
    in
    let version, debug, local_mode, ignore_lines, autogenerated =
      List.map ~f:(fun line -> String.strip line |> String.lowercase) lines
      |> List.foldi ~init:(None, false, None, Int.Map.empty, false) ~f:collect
    in
    let local_mode = Option.value local_mode ~default:Default in
    {
      autogenerated;
      debug;
      local_mode;
      ignore_lines = ignore_lines |> Int.Map.data |> List.concat;
      version = Option.value ~default:3 version;
      number_of_lines = List.length lines;
      raw_hash = [%hash: string list] lines;
    }
end

type t = {
  docstring: string option; [@hash.ignore]
  metadata: Metadata.t;
  relative: string;
  is_external: bool;
  is_stub: bool;
  is_init: bool;
  qualifier: Reference.t;
  statements: Statement.t list;
}
[@@deriving compare, eq, hash, sexp]

let pp format { statements; _ } =
  let print_statement statement = Format.fprintf format "%a\n" Statement.pp statement in
  List.iter statements ~f:print_statement


let show source = Format.asprintf "%a" pp source

let mode ~configuration ~local_mode =
  match configuration, local_mode with
  | { Configuration.Analysis.infer = true; _ }, _ -> Infer
  | { Configuration.Analysis.strict = true; _ }, _
  | _, Some Strict ->
      Strict
  | { Configuration.Analysis.declare = true; _ }, _
  | _, Some Declare ->
      Declare
  | _, Some (DefaultButDontCheck suppressed_codes) -> DefaultButDontCheck suppressed_codes
  | _ -> Default


let create_from_source_path
    ~docstring
    ~metadata
    ~source_path:{ SourcePath.relative; qualifier; is_external; is_init; is_stub; _ }
    statements
  =
  { docstring; metadata; is_external; is_stub; is_init; relative; qualifier; statements }


let create
    ?(docstring = None)
    ?(metadata = Metadata.create_for_testing ())
    ?(relative = "")
    ?(is_external = false)
    statements
  =
  let is_stub = Path.is_path_python_stub relative in
  let is_init = Path.is_path_python_init relative in
  let qualifier = SourcePath.qualifier_of_relative relative in
  { docstring; metadata; is_external; is_stub; is_init; relative; qualifier; statements }


let signature_hash { metadata; is_init; qualifier; statements; _ } =
  let rec statement_hashes statements =
    let statement_hash { Node.value; _ } =
      let open Statement in
      match value with
      | Assign { Assign.target; annotation; value; parent } ->
          [%hash: Expression.t * Expression.t option * Expression.t * Reference.t option]
            (target, annotation, value, parent)
      | Define
          {
            Define.signature =
              { name; parameters; decorators; return_annotation; async; parent; _ };
            _;
          } ->
          [%hash:
            Reference.t
            * Expression.t Parameter.t list
            * Expression.t list
            * Expression.t option
            * bool
            * Reference.t option]
            (name, parameters, decorators, return_annotation, async, parent)
      | Class { Class.name; bases; body; decorators; _ } ->
          [%hash: Reference.t * Expression.Call.Argument.t list * int list * Expression.t list]
            (name, bases, statement_hashes body, decorators)
      | If { If.test; body; orelse } ->
          [%hash: Expression.t * int list * int list]
            (test, statement_hashes body, statement_hashes orelse)
      | Import import -> [%hash: Import.t] import
      | With { With.body; _ } -> [%hash: int list] (statement_hashes body)
      | Assert _
      | Break
      | Continue
      | Delete _
      | Expression _
      | For _
      | Global _
      | Nonlocal _
      | Pass
      | Raise _
      | Return _
      | Try _
      | While _
      | Yield _
      | YieldFrom _ ->
          0
    in
    List.map statements ~f:statement_hash
  in
  [%hash: int * bool * Reference.t * int list]
    (Metadata.signature_hash metadata, is_init, qualifier, statement_hashes statements)


let ignore_lines { metadata = { Metadata.ignore_lines; _ }; _ } = ignore_lines

let statements { statements; _ } = statements

let top_level_define { qualifier; statements; metadata = { Metadata.version; _ }; _ } =
  let statements =
    if version < 3 then
      []
    else
      statements
  in
  Statement.Define.create_toplevel ~qualifier:(Some qualifier) ~statements


let top_level_define_node ({ qualifier; _ } as source) =
  let location =
    {
      Location.path = qualifier;
      start = { Location.line = 1; column = 1 };
      stop = { Location.line = 1; column = 1 };
    }
  in
  Node.create ~location (top_level_define source)


let expand_relative_import ~from { is_init; qualifier; _ } =
  match Reference.show from with
  | "builtins" -> Reference.empty
  | serialized ->
      (* Expand relative imports according to PEP 328 *)
      let dots = String.take_while ~f:(fun dot -> dot = '.') serialized in
      let postfix =
        match String.drop_prefix serialized (String.length dots) with
        (* Special case for single `.`, `..`, etc. in from clause. *)
        | "" -> Reference.empty
        | nonempty -> Reference.create nonempty
      in
      let prefix =
        if not (String.is_empty dots) then
          let initializer_module_offset =
            (* `.` corresponds to the directory containing the module. For non-init modules, the
               qualifier matches the path, so we drop exactly the number of dots. However, for
               __init__ modules, the directory containing it represented by the qualifier. *)
            if is_init then
              1
            else
              0
          in
          List.rev (Reference.as_list qualifier)
          |> (fun reversed -> List.drop reversed (String.length dots - initializer_module_offset))
          |> List.rev
          |> Reference.create_from_list
        else
          Reference.empty
      in
      Reference.combine prefix postfix


let localize_configuration
    ~source:{ metadata = { Metadata.local_mode; debug = local_debug; _ }; _ }
    ({ Configuration.Analysis.debug; strict; _ } as configuration)
  =
  let debug = debug || local_debug in
  let strict, declare =
    match local_mode with
    | Strict -> true, false
    | Unsafe -> false, false
    | Declare -> false, true
    | _ -> strict, false
  in
  { configuration with debug; strict; declare }
