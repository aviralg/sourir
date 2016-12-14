open Instr

let remove_empty_jmp prog =
  let rec remove_empty_jmp pc =
    let pc' = pc + 1 in
    if pc' = Array.length prog then [prog.(pc)] else
      match (prog.(pc), prog.(pc')) with
      | (Goto l1, Label l2) when l1 = l2 ->
          remove_empty_jmp (pc+2)
      | (_, _) ->
          prog.(pc) :: remove_empty_jmp (pc')
  in
  let cleaned = remove_empty_jmp 0 in
  Array.of_list cleaned

let remove_dead_code prog entry=
  let dead_code =
    let init_state = ((), entry) in
    let merge _ _ = None in
    let update _ _ = () in
    Analysis.forward_analysis init_state merge update prog
  in
  let rec remove_dead_code pc =
    if pc = Array.length prog then [] else
      match dead_code.(pc) with
      | None -> remove_dead_code (pc+1)
      | Some _ -> prog.(pc) :: remove_dead_code (pc+1)
  in
  Array.of_list (remove_dead_code 0)

(* TODO: allow pruning of the true branch, but we need not expression for that *)
let branch_prune (prog, scope) =
  (* Convert "branch e l1 l2" to "invalidate e l1; goto l2" *)
  let rec kill_branch pc =
    if pc = Array.length prog then [Stop] else
    match scope.(pc) with
    | Scope.Dead -> assert(false)
    | Scope.Scope scope ->
        begin match prog.(pc) with
        | Branch (exp, l1, l2) ->
            let vars = Scope.VarSet.elements scope in
            Invalidate (exp, "%deopt_" ^ l2, vars) ::
              Goto l1 ::
                kill_branch (pc+1)
        | i ->
            i :: kill_branch (pc+1)
        end
  in
  (* Scan the code and generate a landing-pad for all invalidates *)
  let gen_landing_pad deopt_label =
    let rec gen_landing_pad pc =
      if pc = Array.length prog then [Stop] else
        match prog.(pc) with
        (* this is the entry point, need to create the landing pad label *)
        | Label l when ("%deopt_" ^ l) = deopt_label ->
            Label (l ^ "@" ^ deopt_label) ::
              Label deopt_label :: gen_landing_pad (pc+1)
        (* we need to rename lables since they might clash with main function
         * TODO: this is ugly! what else should we do? *)
        | Label l ->
            Label (l ^ "@" ^ deopt_label) :: gen_landing_pad (pc+1)
        | Goto l ->
            Goto (l ^ "@" ^ deopt_label) :: gen_landing_pad (pc+1)
        | Branch (exp, l1, l2) ->
            Branch (exp, (l1 ^ "@" ^ deopt_label),
                         (l2 ^ "@" ^ deopt_label)) :: gen_landing_pad (pc+1)
        | Invalidate _ -> assert(false)
        | i ->
            i :: gen_landing_pad (pc+1)
    in
    let instrs = Comment ("Landing pad for deopt " ^ deopt_label) ::
      gen_landing_pad 0 in
    let copy = Array.of_list instrs in
    (* so far the landing pad is a copy of the original function. lets remove
     * the unreachable part of the prologue *)
    remove_dead_code copy ((resolve copy deopt_label) - 1)
  in
  let rec gen_deopt_targets = function
    | Invalidate (exp, label, vars) :: rest ->
        gen_landing_pad label :: gen_deopt_targets rest
    | _ :: rest ->
        gen_deopt_targets rest
    | [] -> []
  in
  let killed = kill_branch 0 in
  let landing_pads = gen_deopt_targets killed in
  let final = Array.of_list killed in
  let combined = Array.concat (final :: landing_pads) in
  remove_empty_jmp (remove_dead_code combined 0)
