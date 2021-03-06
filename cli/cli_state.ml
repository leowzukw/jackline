
type display_mode =
  | BuddyList
  | FullScreen
  | Raw

let next_display_mode = function
  | BuddyList  -> FullScreen
  | FullScreen -> Raw
  | Raw        -> BuddyList

type notify_v =
  | Disconnected
  | Connected
  | Notifications
  | Clear
  | Quit

type connect_v =
  | Cancel
  | Connect of Xmpp_callbacks.user_data
  | Success of Xmpp_callbacks.user_data
  | Reconnect
  | Presence of (User.presence * string option * int option)

type state = {
  config_directory            : string                     ; (* set initially *)
  config                      : Xconfig.t                  ; (* set initially *)

  state_mvar                  : notify_v Lwt_mvar.t        ; (* set initially *)
  contact_mvar                : Contact.contact Lwt_mvar.t ; (* set initially *)
  connect_mvar                : connect_v Lwt_mvar.t       ; (* set initially *)

  contacts                    : Contact.contacts           ; (* read from disk, extended by xmpp callbacks *)

  mutable active_contact      : Xjid.t                     ; (* modified by scrolling *)
  mutable last_active_contact : Xjid.t                     ; (* modified by scrolling *)

  mutable notifications       : Xjid.t list                ; (* list to blink *)

  mutable show_offline        : bool                       ; (* F5 stuff *)
  mutable window_mode         : display_mode               ; (* F12 stuff *)
  mutable scrollback          : int                        ; (* scroll-pgup/down state *)

  mutable last_status         : (User.direction * string)  ; (* internal use only *)

  mutable log_height          : int                        ;
  mutable buddy_width         : int                        ;
}

module Notify = struct
  type notify_writer_s = Q | D | C | D_N | C_N

  let to_string = function
    | Q -> "quit"
    | D -> "disconnected"
    | C -> "connected"
    | D_N -> "disconnected_notifications"
    | C_N -> "connected_notifications"

  let notify_writer jid cb fname =
    let open Lwt.Infix in
    let mvar = Lwt_mvar.create Disconnected in
    let write_file buf =
      let open Lwt_unix in
      Lwt.catch (fun () ->
          openfile fname [O_WRONLY ; O_TRUNC ; O_CREAT ] 0o600 >>= fun fd ->
          Persistency.write_data fd buf >>= fun () ->
          close fd)
        (fun _ -> Lwt.return_unit) >>= fun () ->
      match cb with
      | None -> Lwt.return_unit
      | Some x ->
        Lwt.catch (fun () ->
            system (x ^ " " ^ Xjid.full_jid_to_string jid ^ " " ^ buf) >>= fun _ ->
            Lwt.return_unit)
          (fun _ -> Lwt.return_unit)
    in
    let rec loop s0 =
      Lwt_mvar.take mvar >>= fun v ->
      let s1 =
        match v, s0 with
        | Quit, _ -> Q
        | Disconnected, C -> D
        | Disconnected, C_N -> D_N
        | Connected, D -> C
        | Connected, D_N -> C_N
        | Notifications, D -> D_N
        | Notifications, C -> C_N
        | Clear, C_N -> C
        | Clear, D_N -> D
        | _, _ -> s0
      in
      match s1 with
      | Q -> write_file (to_string Q)
      | s when s == s0 -> loop s
      | _ -> write_file (to_string s1) >>= fun () -> loop s1
    in
    Lwt.async (fun () -> loop C) ;
    mvar
end

let (xmpp_session : Xmpp_callbacks.user_data Xmpp_callbacks.XMPPClient.session_data option ref) = ref None

module Connect = struct
  open Lwt.Infix

  let disconnect () =
    Xmpp_callbacks.cancel_keepalive () ;
    Xmpp_callbacks.keepalive_running := false ;
    match !xmpp_session with
    | Some s ->
       Xmpp_callbacks.close s >|= fun () ->
       xmpp_session := None
    | None   ->
       Lwt.return_unit

  let resolve config log =
    let domain = JID.to_idn (Xjid.jid_to_xmpp_jid (`Full config.Xconfig.jid))
    and hostname = config.Xconfig.hostname
    and port = config.Xconfig.port
    in
    let report sockaddr =
      let addr = match sockaddr with
        | Unix.ADDR_INET (inet_addr, port) ->
           Unix.string_of_inet_addr inet_addr ^ " on port " ^ string_of_int port
        | Unix.ADDR_UNIX str -> str
      in
      log (`Local (`Full config.Xconfig.jid, "connecting"), "to " ^ domain ^ " (" ^ addr ^ ")") ;
    in
    Xmpp_callbacks.resolve hostname port domain >|= fun sa ->
    report sa ;
    sa

  let connect_me config log state_mvar users =
    let mvar = Lwt_mvar.create Cancel in
    let failure reason =
      disconnect () >>= fun () ->
      log (`Local (`Full config.Xconfig.jid, "session error"), Printexc.to_string reason) ;
      let conn = fun () -> Lwt_mvar.put mvar Reconnect in
      ignore (Lwt_engine.on_timer 10. false (fun _ -> Lwt.async conn)) ;
      Lwt.return_unit
    in
    let connect user_data (p, s, prio) =
      match config.Xconfig.password with
      | None -> failure (Invalid_argument "no password provided, please restart")
      | Some password ->
         try_lwt
           (resolve config log >>= fun sockaddr ->
            let certname = match config.Xconfig.certificate_hostname with
              | None -> JID.to_idn (Xjid.jid_to_xmpp_jid (`Full config.Xconfig.jid))
              | Some x -> x
            in
            (X509_lwt.authenticator
               (match config.Xconfig.authenticator with
                | `Trust_anchor x -> `Ca_file x
                | `Fingerprint fp -> `Hex_fingerprints (`SHA256, [(certname, fp)]))) >>= fun authenticator ->
            let kind, show = Xmpp_callbacks.presence_to_xmpp p in
            Xmpp_callbacks.connect
              sockaddr
              config.Xconfig.jid certname password
              (kind, show, s, prio) authenticator user_data
              (fun session ->
                 Lwt_mvar.put mvar (Success user_data) >>= fun () ->
                 let users = Contact.fold (fun k v acc ->
                                match v with
                                | `Room r when r.Muc.last_status -> k :: acc
                                | _ -> acc) users []
                 in
                 Lwt_list.iter_s (fun x -> Xmpp_callbacks.Xep_muc.enter_room session (Xjid.jid_to_xmpp_jid (`Bare x))) users)) >|= fun session ->
               xmpp_session := Some session ;
               Lwt.async (fun () -> Xmpp_callbacks.parse_loop session)
      with exn -> failure exn
    in
    let rec reconnect_loop user_data presence =
      Lwt_mvar.take mvar >>= function
        | Cancel -> reconnect_loop None presence
        | Connect user_data ->
           connect user_data presence >>= fun () ->
           reconnect_loop None presence
        | Success user_data ->
           Lwt_mvar.put state_mvar Connected >>= fun () ->
           reconnect_loop (Some user_data) presence
        | Presence p ->
           reconnect_loop user_data p
        | Reconnect ->
           match !xmpp_session, user_data with
           | None, Some u ->
              connect u presence >>= fun () ->
              reconnect_loop (Some u) presence
           | _, u -> reconnect_loop u presence
    in
    Lwt.async (fun () -> reconnect_loop None (`Online, None, config.Xconfig.priority)) ;
    mvar
end

let empty_state config_directory config contacts connect_mvar state_mvar =
  let contact_mvar = Persistency.notify_user config_directory
  and last_status = (`Local (`Full config.Xconfig.jid, ""), "")
  and active = `Bare (fst config.Xconfig.jid)
  in
  {
    config_directory                ;
    config                          ;

    state_mvar                      ;
    contact_mvar                    ;
    connect_mvar                    ;

    contacts                        ;

    active_contact      = active    ;
    last_active_contact = active    ;

    notifications       = []        ;

    show_offline        = true      ;
    window_mode         = BuddyList ;
    scrollback          = 0         ;

    last_status                     ;

    log_height          = 6         ;
    buddy_width         = 24        ;
}


let add_status state dir msg =
  match Contact.find_user state.contacts (fst state.config.Xconfig.jid) with
  | None -> assert false
  | Some self ->
     let self = User.insert_message self dir false true msg in
     Contact.replace_user state.contacts self

let send s ?kind jid id body fail =
  Xmpp_callbacks.send_msg s ?kind jid id body fail

let random_string () =
  let open Nocrypto in
  let rnd = Rng.generate 12 in
  Cstruct.to_string (Base64.encode rnd)

let notify state jid =
  Lwt.async (fun () -> Lwt_mvar.put state.state_mvar Notifications) ;
  if
    List.exists (Xjid.jid_matches jid) state.notifications ||
      (Xjid.jid_matches state.active_contact jid && state.scrollback = 0)
  then
    ()
  else
    state.notifications <- jid :: state.notifications

let active state =
  match Contact.find_contact state.contacts (Xjid.t_to_bare state.active_contact) with
  | None -> assert false
  | Some x -> x

let isactive state jid =
  let bare = Xjid.t_to_bare state.active_contact in
  match active state with
  | `User u when not u.User.expand -> Xjid.jid_matches (`Bare bare) jid
  | _ -> jid = state.active_contact

let isnotified state jid =
  List.exists (Xjid.jid_matches jid) state.notifications

let notified state =
  let leftover = List.filter (fun x -> not (isactive state x)) state.notifications in
  state.notifications <- leftover ;
  if List.length state.notifications = 0 then
    Lwt.async (fun () -> Lwt_mvar.put state.state_mvar Clear)

let active_contacts state =
  let active jid =
    let id = `Bare jid in
    state.show_offline || Xjid.jid_matches id state.active_contact || isnotified state id
  and online contact =
    Contact.active_presence contact <> `Offline
  and self = function
    | `User u when u.User.self -> true
    | _ -> false
  in
  let contacts =
    Contact.fold
      (fun id c acc -> if active id || online c || self c then c :: acc else acc)
      state.contacts []
  in
  List.sort Contact.compare_contact contacts

let active_resources state contact =
  if state.show_offline then
    Contact.all_resources contact
  else
    let tst jid = isnotified state jid || state.active_contact = jid in
    Contact.active_resources tst contact

let potentially_visible_resource state contact =
  match contact, List.length (active_resources state contact) with
  | `Room _, _ -> true
  | `User _, x when x < 2 -> false
  | `User _, _ -> true

let visible_resources state contact =
  if Contact.expanded contact then
    active_resources state contact
  else
    []

let active_contacts_resources state =
  let contacts = active_contacts state in
  List.combine contacts (List.map (visible_resources state) contacts)

let show_resource (contact, res) =
  let bare = Contact.jid contact None in
  bare :: List.map (fun x -> `Full x) (List.map (Contact.full_jid contact) res)

let show_resources rs = List.fold_right (fun rs acc -> (show_resource rs) @ acc) rs []

let all_jids state = show_resources (active_contacts_resources state)

let otr_config user state =
  match user.User.otr_custom_config with
  | None -> state.config.Xconfig.otr_config
  | Some x -> x

let session state =
  match active state with
  | `Room _ -> None
  | `User user -> match state.active_contact with
                  | `Bare _ when user.User.expand -> None
                  | `Bare _ -> User.active_session user
                  | `Full (_, r) -> User.find_session user r

let member state =
  match active state with
  | `Room r -> Muc.member r state.active_contact
  | `User _ -> None

let resource state = match active state with
  | `Room _ -> Utils.option None (fun m -> Some (`Member m)) (member state)
  | `User _ -> Utils.option None (fun s -> Some (`Session s))  (session state)

let self state =
  match Contact.find_user state.contacts (fst state.config.Xconfig.jid) with
  | None -> assert false
  | Some self -> self

let selfsession state =
  match User.find_session (self state) (snd state.config.Xconfig.jid) with
  | None -> assert false
  | Some s -> s

let activate_contact state active =
  let find x = Contact.find_contact state.contacts (Xjid.t_to_bare x)
  and r_jid c id = if Contact.expanded c then id else `Bare (Contact.bare c)
  and update ojid njid =
    state.last_active_contact <- ojid ;
    state.active_contact      <- njid ;
    state.scrollback          <- 0 ;
    state.window_mode         <- BuddyList ;
    notified state
  in
  match find state.active_contact, find active with
  | Some cur, Some now ->
     let ojid = r_jid cur state.active_contact
     and njid = r_jid now active
     in
     if ojid <> njid then update state.active_contact njid
  | None, Some now ->
     let old = match find state.last_active_contact with
       | Some c -> r_jid c state.last_active_contact
       | None -> `Bare (fst state.config.Xconfig.jid)
     and njid = r_jid now active
     in
     update old njid
  | _, None -> assert false

let update_notifications state user oldr newr =
  let bare = user.User.bare_jid in
  let update = function
    | `Bare _ as x -> x
    | `Full (jid, r) when bare = jid && r = oldr -> `Full (jid, newr)
    | `Full _ as x -> x
  in
  let nots = List.map update state.notifications in
  state.notifications <- nots
