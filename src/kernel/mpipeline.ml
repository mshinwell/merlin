(* {{{ COPYING *(

  This file is part of Merlin, an helper for ocaml editors

  Copyright (C) 2013 - 2019  Merlin contributors

  Permission is hereby granted, free of charge, to any person obtaining a
  copy of this software and associated documentation files (the "Software"),
  to deal in the Software without restriction, including without limitation the
  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
  sell copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  The Software is provided "as is", without warranty of any kind, express or
  implied, including but not limited to the warranties of merchantability,
  fitness for a particular purpose and noninfringement. In no event shall
  the authors or copyright holders be liable for any claim, damages or other
  liability, whether in an action of contract, tort or otherwise, arising
  from, out of or in connection with the software or the use or other dealings
  in the Software.

)* }}} *)

let time_shift = ref 0.0

let timed_lazy r x =
  lazy (
    let start = Misc.time_spent () in
    let time_shift0 = !time_shift in
    let update () =
      let delta = Misc.time_spent () -. start in
      let shift = !time_shift -. time_shift0 in
      time_shift := time_shift0 +. delta;
      r := !r +. delta -. shift;
    in
    match Lazy.force x with
    | x -> update (); x
    | exception exn -> update (); Std.reraise exn
  )

module Typer = struct
  type t = {
    errors : exn list lazy_t;
    result : Mtyper.result;
  }
end

module Ppx = struct
  type t = {
    config : Mconfig.t;
    errors : exn list;
    parsetree : Mreader.parsetree;
  }
end

type t = {
  config : Mconfig.t;
  raw_source : Msource.t;
  source : Msource.t lazy_t;
  reader : (Mreader.result * Mconfig.t) lazy_t;
  ppx    : Ppx.t lazy_t;
  typer  : Typer.t lazy_t;

  pp_time     : float ref;
  reader_time : float ref;
  ppx_time    : float ref;
  typer_time  : float ref;
  error_time  : float ref;
}

let raw_source t = t.raw_source

let input_config t = t.config
let input_source t = Lazy.force t.source

let get_lexing_pos t pos =
  Msource.get_lexing_pos
    (input_source t) ~filename:(Mconfig.filename t.config) pos

let with_reader t f =
  Mreader.with_ambient_reader t.config (input_source t) f

let reader t = Lazy.force t.reader

let ppx    t = Lazy.force t.ppx
let typer  t = Lazy.force t.typer

let reader_config    t = (snd (reader t))
let reader_parsetree t = (fst (reader t)).Mreader.parsetree
let reader_comments  t = (fst (reader t)).Mreader.comments
let reader_lexer_errors  t = (fst (reader t)).Mreader.lexer_errors
let reader_parser_errors t = (fst (reader t)).Mreader.parser_errors
let reader_no_labels_for_completion t =
  (fst (reader t)).Mreader.no_labels_for_completion

let ppx_parsetree t = (ppx t).Ppx.parsetree
let ppx_errors    t = (ppx t).Ppx.errors

let final_config  t = (ppx t).Ppx.config

let typer_result t = (typer t).Typer.result
let typer_errors t = Lazy.force (typer t).Typer.errors

let process
    ?(pp_time=ref 0.0)
    ?(reader_time=ref 0.0)
    ?(ppx_time=ref 0.0)
    ?(typer_time=ref 0.0)
    ?(error_time=ref 0.0)
    ?for_completion
    config raw_source =
  let source = timed_lazy pp_time (lazy (
      match Mconfig.(config.ocaml.pp) with
      | None -> raw_source
      | Some { workdir; workval } ->
        let source = Msource.text raw_source in
        let source =
          Pparse.apply_pp
            ~workdir ~filename:Mconfig.(config.query.filename)
            ~source ~pp:workval
        in
        Msource.make source
    )) in
  let reader = timed_lazy reader_time (lazy (
      let lazy source = source in
      let result = Mreader.parse ?for_completion config source in
      let config = result.Mreader.config in
      let config = Mreader.apply_directives config result.Mreader.parsetree in
      let config = Mconfig.normalize config in
      result, config
    )) in
  let ppx = timed_lazy ppx_time (lazy (
      let lazy ({Mreader.parsetree; _}, config) = reader in
      let caught = ref [] in
      Msupport.catch_errors Mconfig.(config.ocaml.warnings) caught @@ fun () ->
      let config, parsetree = Mppx.rewrite config parsetree in
      { Ppx. config; parsetree; errors = !caught }
    )) in
  let typer = timed_lazy typer_time (lazy (
      let lazy { Ppx. config; parsetree; _ } = ppx in
      let result = Mtyper.run config parsetree in
      let errors = timed_lazy error_time (lazy (Mtyper.get_errors result)) in
      { Typer. errors; result }
    )) in
  { config; raw_source; source; reader; ppx; typer;
    pp_time; reader_time; ppx_time; typer_time; error_time }

let make config source =
  process (Mconfig.normalize config) source

let for_completion position
    {config; raw_source;
     pp_time; reader_time; ppx_time; typer_time; error_time; _} =
  process config raw_source ~for_completion:position
    ~pp_time ~reader_time ~ppx_time ~typer_time ~error_time

let timing_information t = [
  "pp"     , !(t.pp_time);
  "reader" , !(t.reader_time);
  "ppx"    , !(t.ppx_time);
  "typer"  , !(t.typer_time);
  "error"  , !(t.error_time);
]
