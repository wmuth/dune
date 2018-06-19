open Import
open Build.O
open Jbuild

module SC = Super_context

let pp_fname fn =
  let fn, ext = Filename.split_extension fn in
  (* We need to to put the .pp before the .ml so that the compiler realises that
     [foo.pp.mli] is the interface for [foo.pp.ml] *)
  fn ^ ".pp" ^ ext

let pped_module ~dir m ~f =
  Module.map_files m ~f:(fun kind file ->
    let pp_fname = pp_fname file.name in
    f kind (Path.relative dir file.name) (Path.relative dir pp_fname);
    { file with name = pp_fname })

module Driver = struct
  module M = struct
    module Info = struct
      let name = Sub_system_name.make "ppx.driver"
      type t =
        { loc        : Loc.t
        ; flags      : Ordered_set_lang.Unexpanded.t
        ; lint_flags : Ordered_set_lang.Unexpanded.t
        ; main       : string
        ; replaces   : (Loc.t * string) list
        }

      type Jbuild.Sub_system_info.t += T of t

      let loc t = t.loc

      (* The syntax of the driver sub-system is part of the main dune
         syntax, so we simply don't create a new one.

         If we wanted to make the ppx system an extension, then we
         would create a new one.
      *)
      let syntax = Jbuild.syntax

      open Sexp.Of_sexp

      let parse =
        record
          (loc >>= fun loc ->
           Ordered_set_lang.Unexpanded.field "flags"      >>= fun      flags ->
           Ordered_set_lang.Unexpanded.field "lint_flags" >>= fun lint_flags ->
           field "main" string >>= fun main ->
           field "replaces" (list (located string)) ~default:[]
           >>= fun replaces ->
           return
             { loc
             ; flags
             ; lint_flags
             ; main
             ; replaces
             })
    end

    (* The [lib] field is lazy so that we don't need to fill it for
       hardcoded [t] values used to implement the jbuild style
       handling of drivers.

       See [Jbuild_driver] below for details. *)
    type t =
      { info     : Info.t
      ; lib      : Lib.t Lazy.t
      ; replaces : t list Or_exn.t
      }

    let desc ~plural = "ppx driver" ^ if plural then "s" else ""
    let desc_article = "a"

    let lib      t = Lazy.force t.lib
    let replaces t = t.replaces

    let instantiate ~resolve ~get lib (info : Info.t) =
      { info
      ; lib = lazy lib
      ; replaces =
          let open Result.O in
          Result.all
            (List.map info.replaces
               ~f:(fun ((loc, name) as x) ->
                 resolve x >>= fun lib ->
                 match get ~loc lib with
                 | None ->
                   Error (Loc.exnf loc "%S is not a %s" name
                            (desc ~plural:false))
                 | Some t -> Ok t))
      }

    let to_sexp t =
      let open Sexp.To_sexp in
      let f x = string (Lib.name (Lazy.force x.lib)) in
      ((1, 0),
       record
         [ "flags"            , Ordered_set_lang.Unexpanded.sexp_of_t
                                  t.info.flags
         ; "lint_flags"       , Ordered_set_lang.Unexpanded.sexp_of_t
                                  t.info.lint_flags
         ; "main"             , string t.info.main
         ; "replaces"         , list f (Result.ok_exn t.replaces)
         ])
  end
  include M
  include Sub_system.Register_backend(M)

  (* Where are we called from? *)
  type loc =
    | User_file of Loc.t * (Loc.t * Pp.t) list
    | Dot_ppx   of Path.t * Pp.t list

  let make_error loc msg =
    match loc with
    | User_file (loc, _) -> Error (Loc.exnf loc "%a" Fmt.text msg)
    | Dot_ppx (path, pps) ->
      Error (Loc.exnf (Loc.in_file (Path.to_string path)) "%a" Fmt.text
               (sprintf
                  "Failed to create on-demand ppx rewriter for %s; %s"
                  (String.enumerate_and (List.map pps ~f:Pp.to_string))
                  (String.uncapitalize msg)))

  let select libs ~loc =
    match select_replaceable_backend libs ~replaces with
    | Ok _ as x -> x
    | Error No_backend_found ->
      let msg =
        match libs with
        | [] ->
          "You must specify at least one ppx rewriter."
        | _ ->
          match
            List.filter_map libs ~f:(fun lib ->
              match Lib.name lib with
              | "ocaml-migrate-parsetree" | "ppxlib" | "ppx_driver" as s ->
                Some s
              | _ -> None)
          with
          | [] ->
            let pps =
              match loc with
              | User_file (_, pps) -> List.map pps ~f:snd
              | Dot_ppx (_, pps) -> pps
            in
            sprintf
              "No ppx driver were found. It seems that %s %s not \
               compatible with Dune. Examples of ppx rewriters that \
               are compatible with Dune are ones using \
               ocaml-migrate-parsetree, ppxlib or ppx_driver."
              (String.enumerate_and (List.map pps ~f:Pp.to_string))
              (match pps with
               | [_] -> "is"
               | _   -> "are")
          | names ->
            sprintf
              "No ppx driver were found.\n\
               Hint: Try upgrading or reinstalling %s."
              (String.enumerate_and names)
      in
      make_error loc msg
    | Error (Too_many_backends ts) ->
      make_error loc
        (sprintf
           "Too many incompatible ppx drivers were found: %s."
           (String.enumerate_and (List.map ts ~f:(fun t ->
              Lib.name (lib t)))))
    | Error (Other exn) ->
      Error exn
end

module Jbuild_driver = struct
  (* This module is used to implement the jbuild handling of ppx
     drivers.  It doesn't implement exactly the same algorithm, but it
     should be enough for all jbuilder packages out there.

     It works as follow: given the list of ppx rewriters specified by
     the user, check whether the last one is named [ppxlib.runner] or
     [ppx_driver.runner]. If it isn't, assume the driver is
     ocaml-migrate-parsetree and use some hard-coded driver
     information. If it is, use the corresponding hardcoded driver
     information. *)

  let make name info : (Pp.t * Driver.t) Lazy.t = lazy (
    let info =
      Sexp.parse_string ~mode:Single ~fname:"<internal>" info
      |> Sexp.Of_sexp.parse Driver.Info.parse Univ_map.empty
    in
    (Pp.of_string name,
     { info
     ; lib = lazy (assert false)
     ; replaces = Ok []
     }))
  let omp = make "ocaml-migrate-parsetree" {|
    ((main       Migrate_parsetree.Driver.run_main)
     (flags      (--dump-ast))
     (lint_flags (--null)))
  |}
  let ppxlib = make "ppxlib" {|
    ((main       Ppxlib.Driver.standalone)
     (flags      (-diff-cmd - -dump-ast))
     (lint_flags (-diff-cmd - -null    )))
  |}
  let ppx_driver = make "ppx_driver" {|
    ((main       Ppx_driver.standalone)
     (flags      (-diff-cmd - -dump-ast))
     (lint_flags (-diff-cmd - -null    )))
  |}

  let drivers =
    [ Pp.of_string "ocaml-migrate-parsetree.driver-main" , omp
    ; Pp.of_string "ppxlib.runner"                       , ppxlib
    ; Pp.of_string "ppx_driver.runner"                   , ppx_driver
    ]

  let get_driver pps =
    let driver =
      match List.last pps with
      | None -> omp
      | Some (_, pp) -> Option.value (List.assoc drivers pp) ~default:omp
    in
    snd (Lazy.force driver)

  (* For building the driver *)
  let analyse_pps pps =
    let driver, rev_others =
      match List.rev pps with
      | [] -> (omp, [])
      | pp :: rev_rest as rev_pps ->
        match List.assoc drivers pp with
        | None        -> (omp   , rev_pps )
        | Some driver -> (driver, rev_rest)
    in
    let driver_pp, driver = Lazy.force driver in
    (driver, List.rev (driver_pp :: rev_others))
end

let ppx_exe sctx ~key ~dir_kind =
  match (dir_kind : File_tree.Dune_file.Kind.t) with
  | Dune ->
    Path.relative (SC.build_dir sctx) (".ppx/" ^ key ^ "/ppx.exe")
  | Jbuild ->
    Path.relative (SC.build_dir sctx) (".ppx/jbuild/" ^ key ^ "/ppx.exe")

let build_ppx_driver sctx ~lib_db ~dep_kind ~target ~dir_kind pps =
  let ctx = SC.context sctx in
  let mode = Context.best_mode ctx in
  let compiler = Option.value_exn (Context.compiler ctx mode) in
  let jbuild_driver, pps =
    match (dir_kind : File_tree.Dune_file.Kind.t) with
    | Dune -> (None, pps)
    | Jbuild ->
      let driver, pps = Jbuild_driver.analyse_pps pps in
      (Some driver, pps)
  in
  let driver_and_libs =
    let open Result.O in
    Result.map_error ~f:(fun e ->
      (* Extend the dependency stack as we don't have locations at
         this point *)
      Dep_path.prepend_exn e
        (Preprocess (pps : Jbuild.Pp.t list :> string list)))
      (Lib.DB.resolve_pps lib_db
         (List.map pps ~f:(fun x -> (Loc.none, x)))
       >>= Lib.closure
       >>= fun resolved_pps ->
       match jbuild_driver with
       | None ->
         Driver.select resolved_pps ~loc:(Dot_ppx (target, pps))
         >>| fun driver ->
         (driver, resolved_pps)
       | Some driver ->
         Ok (driver, resolved_pps))
  in
  (* CR-someday diml: what we should do is build the .cmx/.cmo once
     and for all at the point where the driver is defined. *)
  let ml = Path.relative (Option.value_exn (Path.parent target)) "ppx.ml" in
  SC.add_rule sctx
    (Build.of_result_map driver_and_libs ~f:(fun (driver, _) ->
       Build.return (sprintf "let () = %s ()\n" driver.info.main))
     >>>
     Build.write_file_dyn ml);
  SC.add_rule sctx
    (Build.record_lib_deps ~kind:dep_kind (Lib_deps.of_pps pps)
     >>>
     Build.of_result_map driver_and_libs ~f:(fun (_, libs) ->
       Build.paths (Lib.L.archive_files libs ~mode ~ext_lib:ctx.ext_lib))
     >>>
     Build.run ~context:ctx (Ok compiler)
       [ A "-o" ; Target target
       ; Arg_spec.of_result
           (Result.map driver_and_libs ~f:(fun (_driver, libs) ->
              Lib.L.compile_and_link_flags ~mode ~stdlib_dir:ctx.stdlib_dir
                ~compile:libs
                ~link:libs))
       ; Dep ml
       ])

let get_rules sctx key ~dir_kind =
  let exe = ppx_exe sctx ~key ~dir_kind in
  let (key, lib_db) = SC.Scope_key.of_string sctx key in
  let names =
    match key with
    | "+none+" -> []
    | _ -> String.split key ~on:'+'
  in
  let names =
    match List.rev names with
    | [] -> []
    | driver :: rest -> List.sort rest ~compare:String.compare @ [driver]
  in
  let pps = List.map names ~f:Jbuild.Pp.of_string in
  build_ppx_driver sctx pps ~lib_db ~dep_kind:Required ~target:exe ~dir_kind

let gen_rules sctx components =
  match components with
  | [key] -> get_rules sctx key ~dir_kind:Dune
  | ["jbuild"; key] -> get_rules sctx key ~dir_kind:Jbuild
  | _ -> ()

let ppx_driver_exe sctx libs ~dir_kind =
  let names =
    let names = List.rev_map libs ~f:Lib.name in
    match (dir_kind : File_tree.Dune_file.Kind.t) with
    | Dune -> List.sort names ~compare:String.compare
    | Jbuild ->
      match names with
      | last :: others -> List.sort others ~compare:String.compare @ [last]
      | [] -> []
  in
  let scope_for_key =
    List.fold_left libs ~init:None ~f:(fun acc lib ->
      let scope_for_key =
        match Lib.status lib with
        | Private scope_name   -> Some scope_name
        | Public _ | Installed -> None
      in
      match acc, scope_for_key with
      | Some a, Some b -> assert (a = b); acc
      | Some _, None   -> acc
      | None  , Some _ -> scope_for_key
      | None  , None   -> None)
  in
  let key =
    match names with
    | [] -> "+none+"
    | _  -> String.concat names ~sep:"+"
  in
  let key =
    match scope_for_key with
    | None            -> key
    | Some scope_name -> SC.Scope_key.to_string key scope_name
  in
  ppx_exe sctx ~key ~dir_kind

module Compat_ppx_exe_kind = struct
  type t =
    | Dune
    | Jbuild of string option
end

let get_compat_ppx_exe sctx ~name ~kind =
  match (kind : Compat_ppx_exe_kind.t) with
  | Dune ->
    ppx_exe sctx ~key:name ~dir_kind:Dune
  | Jbuild driver ->
    (* We know both [name] and [driver] are public libraries, so we
       don't add the scope key. *)
    let key =
      match driver with
      | None -> name
      | Some d -> sprintf "%s+%s" name d
    in
    ppx_exe sctx ~key ~dir_kind:Jbuild

let get_ppx_driver sctx ~loc ~scope ~dir_kind pps =
  let sctx = SC.host sctx in
  let open Result.O in
  match (dir_kind : File_tree.Dune_file.Kind.t) with
  | Dune ->
    Lib.DB.resolve_pps (Scope.libs scope) pps
    >>= fun libs ->
    Lib.closure libs
    >>=
    Driver.select ~loc:(User_file (loc, pps))
    >>= fun driver ->
    Ok (ppx_driver_exe sctx libs ~dir_kind, driver)
  | Jbuild ->
    let driver = Jbuild_driver.get_driver pps in
    Lib.DB.resolve_pps (Scope.libs scope) pps
    >>= fun libs ->
    Ok (ppx_driver_exe sctx libs ~dir_kind, driver)

let target_var = String_with_vars.virt_var __POS__ "@"
let root_var   = String_with_vars.virt_var __POS__ "ROOT"

let cookie_library_name lib_name =
  match lib_name with
  | None -> []
  | Some name -> ["--cookie"; sprintf "library-name=%S" name]

(* Generate rules for the reason modules in [modules] and return a
   a new module with only OCaml sources *)
let setup_reason_rules sctx ~dir (m : Module.t) =
  let ctx = SC.context sctx in
  let refmt =
    Artifacts.binary (SC.artifacts sctx) "refmt" ~hint:"opam install reason" in
  let rule src target =
    let src_path = Path.relative dir src in
    Build.run ~context:ctx refmt
      [ A "--print"
      ; A "binary"
      ; Dep src_path ]
      ~stdout_to:(Path.relative dir target) in
  Module.map_files m ~f:(fun _ f ->
    match f.syntax with
    | OCaml  -> f
    | Reason ->
      let ml = Module.File.to_ocaml f in
      SC.add_rule sctx (rule f.name ml.name);
      ml)

let promote_correction fn build ~suffix =
  Build.progn
    [ build
    ; Build.return
        (Action.diff ~optional:true
           fn
           (Path.extend_basename fn ~suffix))
    ]

let lint_module sctx ~dir ~dep_kind ~lint ~lib_name ~scope ~dir_kind =
  Staged.stage (
    let alias = Build_system.Alias.lint ~dir in
    let add_alias fn build =
      SC.add_alias_action sctx alias build
        ~stamp:(List [ Sexp.unsafe_atom_of_string "lint"
                     ; Sexp.To_sexp.(option string) lib_name
                     ; Sexp.atom fn
                     ])
    in
    let lint =
      Per_module.map lint ~f:(function
        | Preprocess.No_preprocessing ->
          (fun ~source:_ ~ast:_ -> ())
        | Action (loc, action) ->
          (fun ~source ~ast:_ ->
             let action = Action.Unexpanded.Chdir (root_var, action) in
             Module.iter source ~f:(fun _ (src : Module.File.t) ->
               let src_path = Path.relative dir src.name in
               add_alias src.name
                 (Build.path src_path
                  >>^ (fun _ -> [src_path])
                  >>> SC.Action.run sctx
                        action
                        ~loc
                        ~dir
                        ~dep_kind
                        ~targets:(Static [])
                        ~scope)))
        | Pps { loc; pps; flags } ->
          let args : _ Arg_spec.t =
            S [ As flags
              ; As (cookie_library_name lib_name)
              ]
          in
          let corrected_suffix = ".lint-corrected" in
          let driver_and_flags =
            let open Result.O in
            get_ppx_driver sctx ~loc ~scope ~dir_kind pps
            >>| fun (exe, driver) ->
            (exe,
             let extra_vars =
               String_map.singleton "corrected-suffix" [Value.String corrected_suffix]
             in
             Build.memoize "ppx flags"
               (SC.expand_and_eval_set sctx driver.info.lint_flags
                  ~scope
                  ~dir
                  ~extra_vars
                  ~standard:(Build.return [])))
          in
          (fun ~source ~ast ->
             Module.iter ast ~f:(fun kind src ->
               add_alias src.name
                 (promote_correction ~suffix:corrected_suffix
                    (Option.value_exn (Module.file ~dir source kind))
                    (Build.of_result_map driver_and_flags ~f:(fun (exe, flags) ->
                       flags >>>
                       Build.run ~context:(SC.context sctx)
                         (Ok exe)
                         [ args
                         ; Ml_kind.ppx_driver_flag kind
                         ; Dep (Path.relative dir src.name)
                         ; Dyn (fun x -> As x)
                         ]))))))
    in
    fun ~(source : Module.t) ~ast ->
      Per_module.get lint source.name ~source ~ast)

type t = (Module.t -> lint:bool -> Module.t) Per_module.t

let dummy = Per_module.for_all (fun m ~lint:_ -> m)

let make sctx ~dir ~dep_kind ~lint ~preprocess
      ~preprocessor_deps ~lib_name ~scope ~dir_kind =
  let preprocessor_deps =
    Build.memoize "preprocessor deps" preprocessor_deps
  in
  let lint_module =
    Staged.unstage (lint_module sctx ~dir ~dep_kind ~lint ~lib_name ~scope
                      ~dir_kind)
  in
  Per_module.map preprocess ~f:(function
    | Preprocess.No_preprocessing ->
      (fun m ~lint ->
         let ast = setup_reason_rules sctx ~dir m in
         if lint then lint_module ~ast ~source:m;
         ast)
    | Action (loc, action) ->
      (fun m ~lint ->
         let ast =
           pped_module m ~dir ~f:(fun _kind src dst ->
             SC.add_rule sctx
               (preprocessor_deps
                >>>
                Build.path src
                >>^ (fun _ -> [src])
                >>>
                SC.Action.run sctx
                  (Redirect
                     (Stdout,
                      target_var,
                      Chdir (root_var,
                             action)))
                  ~loc
                  ~dir
                  ~dep_kind
                  ~targets:(Static [dst])
                  ~scope))
           |> setup_reason_rules sctx ~dir in
         if lint then lint_module ~ast ~source:m;
         ast)
    | Pps { loc; pps; flags } ->
      let args : _ Arg_spec.t =
        S [ As flags
          ; As (cookie_library_name lib_name)
          ]
      in
      let corrected_suffix = ".ppx-corrected" in
      let driver_and_flags =
        let open Result.O in
        get_ppx_driver sctx ~loc ~scope ~dir_kind pps >>| fun (exe, driver) ->
        (exe,
         let extra_vars =
           String_map.singleton "corrected-suffix" [Value.String corrected_suffix]
         in
         Build.memoize "ppx flags"
           (SC.expand_and_eval_set sctx driver.info.flags
              ~scope
              ~dir
              ~extra_vars
              ~standard:(Build.return [])))
      in
      (fun m ~lint ->
         let ast = setup_reason_rules sctx ~dir m in
         if lint then lint_module ~ast ~source:m;
         pped_module ast ~dir ~f:(fun kind src dst ->
           SC.add_rule sctx
             (promote_correction ~suffix:corrected_suffix
                (Option.value_exn (Module.file m ~dir kind))
                (preprocessor_deps >>^ ignore
                 >>>
                 Build.of_result_map driver_and_flags
                   ~targets:[dst]
                   ~f:(fun (exe, flags) ->
                     flags
                     >>>
                     Build.run ~context:(SC.context sctx)
                       (Ok exe)
                       [ args
                       ; A "-o"; Target dst
                       ; Ml_kind.ppx_driver_flag kind; Dep src
                       ; Dyn (fun x -> As x)
                       ]))))))

let pp_modules t ?(lint=true) modules =
  Module.Name.Map.map modules ~f:(fun (m : Module.t) ->
    Per_module.get t m.name m ~lint)

let pp_module_as t ?(lint=true) name m =
  Per_module.get t name m ~lint

let get_ppx_driver sctx ~scope ~dir_kind pps =
  let sctx = SC.host sctx in
  let open Result.O in
  Lib.DB.resolve_pps (Scope.libs scope) pps
  >>| fun libs ->
  ppx_driver_exe sctx libs ~dir_kind
