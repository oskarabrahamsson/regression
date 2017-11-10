(*
  Functions for manipulating the queues in the filesystem on the server,
  including for getting information from GitHub with which to update them.

  We use the filesystem as a database and put all state in it.
  Everything is relative to the current directory.

  We expect to be single-threaded, and use a lock file called
    lock
  to ensure this.

  Job lists are implemented as directories:
    waiting, running, stopped, errored

  Jobs are implemented as files with their id as filename.

  The directory a job is in indicates its status.

  File contents for a job:
    - HOL and CakeML commits
    - optional worker name and start time
    - output
  More concretely:
    CakeML: <SHA>
      <short message> (<date>)
    [#<PR> (<PR-name>)
     Merging into: <SHA>
      <short message> (<date>)]
    HOL: <SHA>
      <short message> (<date>)
    [Machine: <worker name>]

    [<date> Claimed job]
    [<date> <line of output>]
    ...
*)

use "apiLib.sml";

structure serverLib = struct

open apiLib

val text_response_header = "Content-Type:text/plain\n\n"

fun text_response s =
  let
    val () = TextIO.output(TextIO.stdOut, text_response_header)
    val () = TextIO.output(TextIO.stdOut, s)
  in () end

fun cgi_die ls =
  (List.app (fn s => TextIO.output(TextIO.stdOut, s))
     (text_response_header::"Error:\n"::ls);
   TextIO.output(TextIO.stdOut,"\n");
   OS.Process.exit OS.Process.success;
   raise (Fail "impossible"))

fun cgi_assert b ls = if b then () else cgi_die ls

local
  open Posix.IO Posix.FileSys
  val flock = FLock.flock {ltype=F_WRLCK, whence=SEEK_SET, start=0, len=0, pid=NONE}
  val smode = S.flags[S.irusr,S.iwusr,S.irgrp,S.iroth]
  val lock_name = "lock"
in
  fun acquire_lock() =
    let
      val fd = Posix.FileSys.creat(lock_name,smode)
      val _ = Posix.IO.setlkw(fd,flock)
    in fd end
end

type obj = { hash : string, message : string, date : Date.date }
val empty_obj : obj = { hash = "", message = "", date = Date.fromTimeUniv Time.zeroTime }
fun with_hash x (obj : obj) : obj = { hash = x, message = #message obj, date = #date obj }
fun with_message x (obj : obj) : obj = { hash = #hash obj, message = x, date = #date obj }
fun with_date d (obj : obj) : obj = { hash = #hash obj, message = #message obj, date = d }

type pr = { num : int, head_ref : string, head_obj : obj, base_obj : obj }
val empty_pr : pr = { num = 0, head_ref = "", head_obj = empty_obj, base_obj = empty_obj }
fun with_num x (pr : pr) : pr = { num = x, head_ref = #head_ref pr, head_obj = #head_obj pr, base_obj = #base_obj pr }
fun with_head_ref x (pr : pr) : pr = { num = #num pr, head_ref = x, head_obj = #head_obj pr, base_obj = #base_obj pr }
fun with_head_obj x (pr : pr) : pr = { num = #num pr, head_ref = #head_ref pr, head_obj = x, base_obj = #base_obj pr }
fun with_base_obj x (pr : pr) : pr = { num = #num pr, head_ref = #head_ref pr, head_obj = #head_obj pr, base_obj = x }

datatype integration = Branch of string * obj | PR of pr
type snapshot = { cakeml : integration, hol : obj }

fun bare_of_pr ({num,head_ref,head_obj,base_obj}:pr) : bare_pr =
  {head_sha = #hash head_obj, base_sha = #hash base_obj}
fun bare_of_integration (Branch (_,obj)) = Bbr (#hash obj)
  | bare_of_integration (PR pr) = Bpr (bare_of_pr pr)
fun bare_of_snapshot ({cakeml,hol}:snapshot) : bare_snapshot =
  {bcml = bare_of_integration cakeml, bhol = #hash hol}

type log_entry = Date.date * line
type log = log_entry list

type job = {
  id : int,
  snapshot : snapshot,
  claimed : (worker_name * Date.date) option,
  output : log
}

val machine_date = Date.fmt "%Y-%m-%dT%H:%M:%SZ"
val pretty_date = Date.fmt "%b %d %H:%M:%S"
val pretty_date_moment = "MMM DD HH:mm:ss"

fun print_claimed out (worker,date) =
  let
    fun pr s = TextIO.output(out,s)
    val prl = List.app pr
  in
    prl ["Machine: ",worker,"\n\n",machine_date date," Claimed job\n"]
  end

fun print_log_entry out (date,line) =
  let
    fun pr s = TextIO.output(out,s)
    val prl = List.app pr
  in
    prl [machine_date date, " ", line, "\n"]
  end

fun print_snapshot out (s:snapshot) =
  let
    fun pr s = TextIO.output(out,s)
    val prl = List.app pr
    fun print_obj obj =
      prl [#hash obj, "\n  ", #message obj, " (", Date.fmt "%d/%m/%y" (#date obj), ")\n"]

    val () = pr "CakeML: "
    val () =
      case #cakeml s of
        Branch (head_ref,base_obj) => print_obj base_obj
      | PR {num,head_ref,head_obj,base_obj} => (
               print_obj head_obj;
               prl ["#", Int.toString num, " (", head_ref, ")\nMerging into: "];
               print_obj base_obj
             )
    val () = pr "HOL: "
    val () = print_obj (#hol s)
  in () end

fun print_job out (j:job) =
  let
    val () = print_snapshot out (#snapshot j)
    val () = case #claimed j of NONE => () | SOME claimed => print_claimed out claimed
    val () = List.app (print_log_entry out) (#output j)
  in () end

val queue_dirs = ["waiting","running","stopped","errored"]

local
  open OS.FileSys
in
  fun ensure_queue_dirs () =
    let
      val dir = openDir(getDir())
      fun loop ls =
        case readDir dir of NONE => ls
      | SOME d => if isDir d then loop (List.filter(not o equal d) ls)
                  else if List.exists (equal d) ls then cgi_die [d," exists and is not a directory"]
                  else loop ls
    in
      List.app mkDir (loop queue_dirs) before closeDir dir
    end
end

local
  open OS.FileSys
in
  fun read_list q () =
    let
      val dir = openDir q handle OS.SysErr _ => cgi_die ["could not open ",q," directory"]
      fun badFile f = cgi_die ["found bad filename ",f," in ",q]
      fun loop acc =
        case readDir dir of NONE => acc before closeDir dir
      | SOME f => if isDir (OS.Path.concat(q,f)) handle OS.SysErr _ => cgi_die [f, " disappeared from ", q, " unexpectedly"]
                  then cgi_die ["found unexpected directory ",f," in ",q]
                  else case Int.fromString f of NONE => badFile f
                       | SOME id => if check_id f id then loop (insert id acc) else badFile f
      val ids = loop []
    in ids end
  fun clear_list q =
    let
      val dir = openDir q handle OS.SysErr _ => cgi_die ["could not open ",q," directory"]
      fun loop () =
        case readDir dir of NONE => closeDir dir
      | SOME f =>
        let
          val f = OS.Path.concat(q,f)
          val () = remove f
                   handle (e as OS.SysErr _) =>
                     cgi_die ["unexpected error removing ",f,"\n",exnMessage e]
        in loop () end
    in loop () end
end

val waiting = read_list "waiting"
val running = read_list "running"
val stopped = read_list "stopped"
val errored = read_list "errored"

val queue_funs = [waiting,running,stopped,errored]

fun queue_of_job f =
  let
    fun mk_path dir = OS.Path.concat(dir,f)
    fun access dir = OS.FileSys.access(mk_path dir, [OS.FileSys.A_READ])
  in
    find access queue_dirs
    handle Match => cgi_die ["job ",f," not found"]
  end

fun read_job_snapshot q id : bare_snapshot =
  let
    val f = OS.Path.concat(q,Int.toString id)
    val inp = TextIO.openIn f handle IO.Io _ => cgi_die ["cannot open ",f]
    val bs = read_bare_snapshot inp
             handle Option => cgi_die [f," has invalid file format"]
    val () = TextIO.closeIn inp
  in bs end

fun read_head_sha inp =
  let
    val {bcml,...} = read_bare_snapshot inp
  in
    case bcml of Bbr sha => sha | Bpr {head_sha,...} => head_sha
  end

fun filter_out q ids snapshots =
  let
    exception Return
    fun check_null x = if List.null x then raise Return else x
    fun remove_all_matching_this_id (id,snapshots) =
      check_null
        (List.filter (not o (equal (read_job_snapshot q id)) o bare_of_snapshot) snapshots)
  in
    List.foldl remove_all_matching_this_id snapshots ids
    handle Return => []
  end

fun first_unused_id avoid_ids id =
  let
    fun loop id =
      if List.exists (equal id) avoid_ids
      then loop (id+1) else id
  in loop id end

fun add_waiting avoid_ids (snapshot,id) =
  let
    val id = first_unused_id avoid_ids id
    val f = Int.toString id
    val path = OS.Path.concat("waiting",f)
    val () = cgi_assert (not(OS.FileSys.access(path, []))) ["job ",f," already exists waiting"]
    val out = TextIO.openOut path
    val () = print_snapshot out snapshot
    val () = TextIO.closeOut out
  in id+1 end

structure GitHub = struct
  val token = until_space (file_to_string "token")
  val graphql_endpoint = "https://api.github.com/graphql"
  fun graphql_curl_cmd query = (curl_path,["--silent","--show-error",
    "--header",String.concat["Authorization: bearer ",token],
    "--request","POST",
    "--data",String.concat["{\"query\" : \"",query,"\"}"],
    graphql_endpoint])
  val graphql = system_output cgi_die o graphql_curl_cmd

  fun cakeml_status_endpoint sha =
    String.concat["/repos/CakeML/cakeml/statuses/",sha]

  fun status_json id (st,desc) =
    String.concat[
      "{\"state\":\"",st,"\",",
      "\"target_url\":\"https://cakeml.org/regression.cgi/job/",id,"\",",
      "\"description\":\"",desc,"\",",
      "\"context\":\"cakeml-regression-test\"}"]

  val rest_endpoint = "https://api.github.com"
  val rest_version = "application/vnd.github.v3+json"
  fun rest_curl_cmd endpoint data = (curl_path,["--silent","--show-error",
    "--header",String.concat["Authorization: bearer ",token],
    "--header",String.concat["Accept: ",rest_version],
    "--write-out", "%{http_code}",
    "--output", "/dev/null",
    "--request","POST",
    "--data",data,
    String.concat[rest_endpoint,endpoint]])

  val pending_status = ("pending","regression test in progress")
  val success_status = ("success","regression test succeeded")
  val failure_status = ("failure","regression test failed")
  val unknown_status = ("error","regression test aborted")
  fun set_status id sha sd =
    let
      val cmd =
        rest_curl_cmd
          (cakeml_status_endpoint sha)
          (status_json id sd)
      val response = system_output cgi_die cmd
    in
      cgi_assert
        (String.isPrefix "201" response)
        ["Error setting GitHub commit status\n",response]
    end
end

fun read_status inp =
  let
    fun loop () =
      case TextIO.inputLine inp of NONE => GitHub.unknown_status
      | SOME line =>
        if String.isSubstring "FAILED" line
          then GitHub.failure_status
        else if String.isSubstring "SUCCESS" line
          then GitHub.success_status
        else loop ()
  in loop () end

val cakeml_query = String.concat [
  "{repository(name: \\\"cakeml\\\", owner: \\\"CakeML\\\"){",
  "defaultBranchRef { target { ... on Commit {",
  " oid messageHeadline committedDate }}}",
  "pullRequests(baseRefName: \\\"master\\\", first: 100, states: [OPEN]",
  " orderBy: {field: CREATED_AT, direction: DESC}){",
  " nodes { mergeable number headRefName",
  " headRef { target { ... on Commit {",
  " oid messageHeadline committedDate }}}",
  "}}}}" ]

val hol_query = String.concat [
  "{repository(name: \\\"HOL\\\", owner: \\\"HOL-Theorem-Prover\\\"){",
  "defaultBranchRef { target { ... on Commit {",
  " oid messageHeadline committedDate }}}}}" ]

structure ReadJSON = struct

  exception ReadFailure of string
  fun die ls = raise (ReadFailure (String.concat ls))

  type 'a basic_reader = substring -> ('a * substring)
  type 'a reader = 'a -> 'a basic_reader

  fun transform f (reader:'a basic_reader) : 'b reader
  = fn acc => fn ss =>
    let val (v, ss) = reader ss
    in (f v acc, ss) end

  val replace_acc : 'a basic_reader -> 'a reader =
    fn r => transform (fn x => fn _ => x) r

  fun read1 ss c =
    case Substring.getc ss of SOME (c',ss) =>
      if c = c' then ss
      else die ["expected ",String.str c," got ",String.str c']
    | _ => die ["expected ",String.str c," got nothing"]

  val read_string : string basic_reader = fn ss =>
    let
      val ss = read1 ss #"\""
      fun loop ss acc =
        let
          val (chunk,ss) = Substring.splitl (not o equal #"\"") ss
          val z = Substring.size chunk
          val (c,ss) = Substring.splitAt(ss,1)
        in
          if 0 < z andalso Substring.sub(chunk,z-1) = #"\\" then
              loop ss (c::chunk::acc)
          else
            (Option.valOf(String.fromCString(Substring.concat(List.rev(chunk::acc)))),
             ss)
        end
    in
      loop ss []
    end

  val int_from_ss = Option.valOf o Int.fromString o Substring.string

  fun bare_read_date ss =
    let
      val (year,ss) = Substring.splitAt(ss,4)
      val ss = read1 ss #"-"
      val (month,ss) = Substring.splitAt(ss,2)
      val ss = read1 ss #"-"
      val (day,ss) = Substring.splitAt(ss,2)
      val ss = read1 ss #"T"
      val (hour,ss) = Substring.splitAt(ss,2)
      val ss = read1 ss #":"
      val (minute,ss) = Substring.splitAt(ss,2)
      val ss = read1 ss #":"
      val (second,ss) = Substring.splitAt(ss,2)
      val ss = read1 ss #"Z"
      val date = Date.date {
        day = int_from_ss day,
        hour = int_from_ss hour,
        minute = int_from_ss minute,
        month = month_from_int (int_from_ss month),
        offset = SOME (Time.zeroTime),
        second = int_from_ss second,
        year = int_from_ss year }
    in (date, ss) end
    handle Subscript => raise Option | ReadFailure _ => raise Option

  fun read_date ss =
    let
      val (s, ss) = read_string ss
      val (date, e) = bare_read_date (Substring.full s)
      val () = if Substring.isEmpty e then () else raise Option
    in (date, ss) end

  fun read_dict (dispatch : (string * 'a reader) list) : 'a reader
  = fn acc => fn ss =>
    let
      val ss = read1 ss #"{"
      fun loop ss acc =
        case Substring.getc ss of
          SOME(#"}",ss) => (acc, ss)
        | SOME(#",",ss) => loop ss acc
        | _ =>
          let
            val (key, ss) = read_string ss
            val ss = read1 ss #":"
            val (acc, ss) = assoc key dispatch acc ss
          in loop ss acc end
    in loop ss acc end

  fun read_opt_list read_item acc ss =
    let
      val ss = read1 ss #"["
      fun loop ss acc =
        case Substring.getc ss of
          SOME(#"]",ss) => (List.rev acc, ss)
        | SOME(#",",ss) => loop ss acc
        | _ =>
          (case read_item ss
           of (NONE, ss) => loop ss acc
            | (SOME v, ss) => loop ss (v::acc))
    in loop ss acc end

  fun mergeable_only "MERGEABLE" acc = acc
    | mergeable_only _ _ = NONE

  fun read_number ss =
    let val (n,ss) = Substring.splitl Char.isDigit ss
    in (int_from_ss n, ss) end

  val read_obj : obj basic_reader =
    read_dict
      [("oid", transform with_hash read_string)
      ,("messageHeadline", transform with_message read_string)
      ,("committedDate", transform with_date read_date)
      ] empty_obj

  val read_pr : pr option basic_reader =
    read_dict
      [("mergeable", transform mergeable_only read_string)
      ,("number", transform (Option.map o with_num) read_number)
      ,("headRefName", transform (Option.map o with_head_ref) read_string)
      ,("headRef",
        read_dict
          [("target", transform (Option.map o with_head_obj) read_obj)])]
      (SOME empty_pr)

end

local
  open ReadJSON
in
  fun get_current_snapshots () : snapshot list =
    let
      val response = GitHub.graphql cakeml_query
      fun add_master obj acc = (Branch("master",obj)::acc)
      (* This assumes the PR base always matches master.
         We could read it from GitHub instead. *)
      fun add_prs prs [m as (Branch(_,base_obj))] =
        m :: (List.map (PR o with_base_obj base_obj) prs)
      | add_prs _ _ = cgi_die ["add_prs"]
      val (cakeml_integrations,ss) =
        read_dict
        [("data",
          read_dict
          [("repository",
            read_dict
            [("defaultBranchRef",
              read_dict
              [("target", transform add_master read_obj)])
            ,("pullRequests",
              read_dict
              [("nodes", transform add_prs (read_opt_list read_pr []))])
            ])])] []
        (Substring.full response)
      val response = GitHub.graphql hol_query
      val (hol_obj,ss) =
        read_dict
        [("data",
          read_dict
          [("repository",
            read_dict
            [("defaultBranchRef",
              read_dict
              [("target", replace_acc read_obj)])])])]
        empty_obj (Substring.full response)
    in
      List.map (fn i => { cakeml = i, hol = hol_obj } )
        (List.rev cakeml_integrations) (* after rev: oldest pull request first, master last *)
    end
    handle ReadFailure s => cgi_die["Could not read response from GitHub: ",s]
end

val html_response_header = "Content-Type:text/html\n\n<!doctype html>"

structure HTML = struct
  val attributes = List.map (fn (k,v) => String.concat[k,"='",v,"'"])
  fun start_tag tag [] = String.concat["<",tag,">"]
    | start_tag tag attrs = String.concat["<",tag," ",String.concatWith" "(attributes attrs),">"]
  fun end_tag tag = String.concat["</",tag,">"]
  fun element tag attrs body = String.concat[start_tag tag attrs, String.concat body, end_tag tag]
  fun elt tag body = element tag [] [body]
  val html = element "html" [("lang","en")]
  val head = element "head" []
  val meta = start_tag "meta" [("charset","utf-8")]
  val stylesheet = start_tag "link" [("rel","stylesheet"),("type","text/css"),("href","/regression-style.css")]
  val momentjs = element "script" [("src","https://cdnjs.cloudflare.com/ajax/libs/moment.js/2.19.1/moment.min.js")] []
  val localisejs = element "script" [] [
    "function localiseTimes() {",
    "var ls = document.getElementsByTagName(\"time\");",
    "for (var i = 0; i < ls.length; i++) {",
    "ls[i].innerHTML = moment(ls[i].getAttribute(\"datetime\")).format(\"",
    pretty_date_moment,"\");}}"]
  val title = elt "title" "CakeML Regression Test"
  val shortcut = start_tag "link" [("rel","shortcut icon"),("href","/cakeml-icon.png")]
  val header = head [meta,stylesheet,title,shortcut,momentjs,localisejs]
  val body = element "body" [("onload","localiseTimes()")]
  val h2 = elt "h2"
  val h3 = elt "h3"
  val strong = elt "strong"
  val pre = elt "pre"
  fun time d = element "time" [("datetime",machine_date d)] [pretty_date d]
  fun a href body = element "a" [("href",href)] [body]
  val span = elt "span"
  val li = elt "li"
  fun ul ls = element "ul" [] (List.map li ls)
end

datatype html_request = Overview | DisplayJob of id

local
  open HTML
in

  fun job_link q id =
    let
      val jid = Int.toString id
      val f = OS.Path.concat(q,jid)
      val inp = TextIO.openIn f
      val typ = read_job_type inp
                handle IO.Io _ => cgi_die ["cannot open ",f]
                     | Option => cgi_die [f," has invalid file format"]
      val () = TextIO.closeIn inp
    in
      String.concat[a (String.concat["job/",jid]) jid, " ",
                    span (String.concat ["(", typ, ")"])]
    end

  fun capitalise s = String.concat[String.str(Char.toUpper(String.sub(s,0))),String.extract(s,1,NONE)]

  fun html_job_list (q,ids) =
    if List.null ids then []
    else [h2 (capitalise q), ul (List.map (job_link q) ids)]

  val cakeml_github = "https://github.com/CakeML/cakeml"
  val hol_github = "https://github.com/HOL-Theorem-Prover/HOL"
  fun cakeml_commit_link s =
    a (String.concat[cakeml_github,"/commit/",s]) s
  fun hol_commit_link s =
    a (String.concat[hol_github,"/commit/",s]) s
  fun cakeml_pr_link ss =
    a (String.concat[cakeml_github,"/pull/",Substring.string(Substring.triml 1 ss)]) (Substring.string ss)

  fun escape_char #"<" = "&lt;"
    | escape_char #">" = "&gt;"
    | escape_char c = if Char.isPrint c orelse Char.isSpace c then String.str c else ""
  val escape = String.translate escape_char

  fun process s =
    let
      val inp = TextIO.openString s
      fun read_line () = Option.valOf (TextIO.inputLine inp)
      val prefix = "CakeML: "
      val sha = extract_prefix_trimr prefix (read_line ()) handle Option => cgi_die ["failed to find line ",prefix]
      val acc = [String.concat[strong prefix,cakeml_commit_link sha,"\n"]]
      val acc = escape (read_line ()) :: acc (* msg *)
      val line = read_line ()
      val (line,acc) =
        if String.isPrefix "#" line then
          let
            val ss = Substring.full line
            val (pr,rest) = Substring.splitl (not o Char.isSpace) ss
            val line = String.concat[cakeml_pr_link pr, escape (Substring.string rest)]
            val acc = line::acc
            val prefix = "Merging into: "
            val sha = extract_prefix_trimr prefix (read_line ()) handle Option => cgi_die ["failed to find line ",prefix]
            val acc = (String.concat[strong prefix,cakeml_commit_link sha,"\n"])::acc
            val acc = escape (read_line ()) :: acc
          in (read_line (), acc) end
        else (line,acc)
      val prefix = "HOL: "
      val sha = extract_prefix_trimr prefix line handle Option => cgi_die ["failed to find line ",prefix]
      val acc = (String.concat[strong prefix,hol_commit_link sha,"\n"])::acc
      val acc = escape (read_line ()) :: acc (* msg *)
      exception Return of string list
      val acc =
        let
          val prefix = "Machine: "
          val line = read_line () handle Option => raise (Return acc)
          val name = extract_prefix_trimr prefix line handle Option => raise (Return (line::acc))
          val acc = (String.concat[strong prefix,escape name,"\n"])::acc
          val line = read_line () handle Option => raise (Return acc)
        in
          if String.size line = 1 then line::acc else raise (Return (line::acc))
        end handle Return acc => escape (TextIO.inputAll inp) :: acc
      fun loop acc =
        let
          val line = read_line()
        in
          let
            val (date,rest) = ReadJSON.bare_read_date (Substring.full line)
            val line =
              String.concat
               [time date,
                escape (Substring.string rest)]
          in
            loop (line::acc)
          end handle Option => escape (TextIO.inputAll inp) :: acc
        end handle Option => acc
    in
      String.concat(List.rev (loop acc)) before
      TextIO.closeIn inp
    end

  fun req_body Overview =
    List.concat
      (ListPair.map html_job_list
         (queue_dirs,
          List.map (fn f => f()) queue_funs))
    @ [a "api/refresh" "refresh from GitHub"]
  | req_body (DisplayJob id) =
    let
      val jid = Int.toString id
      val q = queue_of_job jid
      val f = OS.Path.concat(q,jid)
      val s = file_to_string f
    in
      [a ".." "Overview", h3 (a jid (String.concat["Job ",jid])), pre (process s)]
    end

  fun html_response req =
    let
      val () = TextIO.output(TextIO.stdOut, html_response_header)
      val () = TextIO.output(TextIO.stdOut, html ([header,body (req_body req)]))
    in () end

end

end
