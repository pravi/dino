using Gee;
using Qlite;

using Xmpp;
using Xmpp.Xep;
using Dino.Entities;

public class Dino.Reactions : StreamInteractionModule, Object {
    public static ModuleIdentity<Reactions> IDENTITY = new ModuleIdentity<Reactions>("reactions");
    public string id { get { return IDENTITY.id; } }

    public signal void reaction_added(Account account, int content_item_id, Jid jid, string reaction);
//    [Signal(detailed=true)]
    public signal void reaction_removed(Account account, int content_item_id, Jid jid, string reaction);

    private StreamInteractor stream_interactor;
    private Database db;
    private HashMap<string, Gee.List<ReactionInfo>> reaction_infos = new HashMap<string, Gee.List<ReactionInfo>>();

    public static void start(StreamInteractor stream_interactor, Database database) {
        Reactions m = new Reactions(stream_interactor, database);
        stream_interactor.add_module(m);
    }

    private Reactions(StreamInteractor stream_interactor, Database database) {
        this.stream_interactor = stream_interactor;
        this.db = database;
        stream_interactor.account_added.connect(on_account_added);

        stream_interactor.get_module(MessageProcessor.IDENTITY).message_sent_or_received.connect(on_new_message);
    }

    public void add_reaction(Conversation conversation, ContentItem content_item, string reaction) {
        Gee.List<string> reactions = get_own_reactions(conversation, content_item);
        if (!reactions.contains(reaction)) {
            reactions.add(reaction);
        }
        send_reactions(conversation, content_item, reactions);
        reaction_added(conversation.account, content_item.id, conversation.account.bare_jid, reaction);
    }

    public void remove_reaction(Conversation conversation, ContentItem content_item, string reaction) {
        Gee.List<string> reactions = get_own_reactions(conversation, content_item);
        reactions.remove(reaction);
        send_reactions(conversation, content_item, reactions);
        reaction_removed(conversation.account, content_item.id, conversation.account.bare_jid, reaction);
    }

    public Gee.List<ReactionUsers> get_item_reactions(Conversation conversation, ContentItem content_item) {
        if (conversation.type_ == Conversation.Type.CHAT) {
            return get_chat_message_reactions(conversation.account, content_item);
        } else {
            return get_muc_message_reactions(conversation.account, content_item);
        }
    }

    public async bool conversation_supports_reactions(Conversation conversation) {
        if (conversation.type_ == Conversation.Type.CHAT) {
            Gee.List<Jid>? resources = stream_interactor.get_module(PresenceManager.IDENTITY).get_full_jids(conversation.counterpart, conversation.account);
            if (resources == null) return false;

            foreach (Jid full_jid in resources) {
                bool? has_feature = yield stream_interactor.get_module(EntityInfo.IDENTITY).has_feature(conversation.account, full_jid, Xep.Reactions.NS_URI);
                if (has_feature == true) {
                    return true;
                }
            }
        } else {
            // The MUC server needs to 1) support stable stanza ids 2) either support occupant ids or be a private room (where we know real jids)
            var entity_info = stream_interactor.get_module(EntityInfo.IDENTITY);
            bool server_supports_sid = (yield entity_info.has_feature(conversation.account, conversation.counterpart.bare_jid, Xep.UniqueStableStanzaIDs.NS_URI)) ||
                    (yield entity_info.has_feature(conversation.account, conversation.counterpart.bare_jid, Xmpp.MessageArchiveManagement.NS_URI_2));
            if (!server_supports_sid) return false;

            bool? supports_occupant_ids = yield entity_info.has_feature(conversation.account, conversation.counterpart, Xep.OccupantIds.NS_URI);
            if (supports_occupant_ids) return true;

            return stream_interactor.get_module(MucManager.IDENTITY).is_private_room(conversation.account, conversation.counterpart);
        }
        return false;
    }

    private void send_reactions(Conversation conversation, ContentItem content_item, Gee.List<string> reactions) {
        Message? message = null;

        FileItem? file_item = content_item as FileItem;
        if (file_item != null) {
            int message_id = int.parse(file_item.file_transfer.info);
            message = stream_interactor.get_module(MessageStorage.IDENTITY).get_message_by_id(message_id, conversation);
        }
        MessageItem? message_item = content_item as MessageItem;
        if (message_item != null) {
            message = message_item.message;
        }

        if (message == null) {
            return;
        }

        XmppStream stream = stream_interactor.get_stream(conversation.account);
        if (conversation.type_ == Conversation.Type.GROUPCHAT || conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
            if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                stream.get_module(Xmpp.Xep.Reactions.Module.IDENTITY).send_reaction(stream, conversation.counterpart, "groupchat", message.server_id ?? message.stanza_id, reactions);
            } else if (conversation.type_ == Conversation.Type.GROUPCHAT_PM) {
                stream.get_module(Xmpp.Xep.Reactions.Module.IDENTITY).send_reaction(stream, conversation.counterpart, "chat", message.server_id ?? message.stanza_id, reactions);
            }
            // We save the reaction when it gets reflected back to us
        } else if (conversation.type_ == Conversation.Type.CHAT) {
            stream.get_module(Xmpp.Xep.Reactions.Module.IDENTITY).send_reaction(stream, conversation.counterpart, "chat", message.stanza_id, reactions);
            var datetime_now = new DateTime.now();
            long now_long = (long) (datetime_now.to_unix() * 1000 + datetime_now.get_microsecond());
            save_chat_reactions(conversation.account, conversation.account.bare_jid, content_item.id, now_long, reactions);
        }
    }

    private Gee.List<string> get_own_reactions(Conversation conversation, ContentItem content_item) {
        if (conversation.type_ == Conversation.Type.CHAT) {
            return get_chat_user_reactions(conversation.account, content_item.id, conversation.account.bare_jid)
                    .emojis;
        } else if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            string own_occupant_id = stream_interactor.get_module(MucManager.IDENTITY).get_own_occupant_id(conversation.account, content_item.jid);
            return get_muc_user_reactions(conversation.account, content_item.id, own_occupant_id, conversation.account.bare_jid)
                    .emojis;
        }
        return new ArrayList<string>();
    }

    private class ReactionsTime {
        public Gee.List<string>? emojis = null;
        public long time = -1;
    }

    private ReactionsTime get_chat_user_reactions(Account account, int content_item_id, Jid jid) {
        int jid_id = db.get_jid_id(jid);

        QueryBuilder query = db.reaction.select()
            .with(db.reaction.account_id, "=", account.id)
            .with(db.reaction.content_item_id, "=", content_item_id)
            .with(db.reaction.jid_id, "=", jid_id);

        RowOption row = query.single().row();
        ReactionsTime ret = new ReactionsTime();
        if (row.is_present()) {
            ret.emojis = string_to_emoji_list(row[db.reaction.emojis]);
            ret.time = row[db.reaction.time];
        } else {
            ret.emojis = new ArrayList<string>();
            ret.time = -1;
        }
        return ret;
    }

    private ReactionsTime get_muc_user_reactions(Account account, int content_item_id, string? occupantid, Jid? real_jid) {
        QueryBuilder query = db.reaction.select()
                .with(db.reaction.account_id, "=", account.id)
                .with(db.reaction.content_item_id, "=", content_item_id)
                .join_with(db.occupantid, db.occupantid.id, db.reaction.occupant_id)
                .with(db.occupantid.occupant_id, "=", occupantid);

        RowOption row = query.single().row();
        ReactionsTime ret = new ReactionsTime();
        if (row.is_present()) {
            ret.emojis = string_to_emoji_list(row[db.reaction.emojis]);
            ret.time = row[db.reaction.time];
        } else {
            ret.emojis = new ArrayList<string>();
            ret.time = -1;
        }
        return ret;
    }

    private Gee.List<string> string_to_emoji_list(string emoji_str) {
        ArrayList<string> ret = new ArrayList<string>();
        foreach (string emoji in emoji_str.split(",")) {
            if (emoji.length != 0)
            ret.add(emoji);
        }
        return ret;
    }

    public Gee.List<ReactionUsers> get_chat_message_reactions(Account account, ContentItem content_item) {
        QueryBuilder select = db.reaction.select()
                .with(db.reaction.account_id, "=", account.id)
                .with(db.reaction.content_item_id, "=", content_item.id)
                .order_by(db.reaction.time, "DESC");

        var ret = new ArrayList<ReactionUsers>();
        var index = new HashMap<string, ReactionUsers>();
        foreach (Row row in select) {
            string emoji_str = row[db.reaction.emojis];
            Jid jid = db.get_jid_by_id(row[db.reaction.jid_id]);

            foreach (string emoji in emoji_str.split(",")) {
                if (!index.has_key(emoji)) {
                    index[emoji] = new ReactionUsers() { reaction=emoji, jids=new ArrayList<Jid>(Jid.equals_func) };
                    ret.add(index[emoji]);
                }
                index[emoji].jids.add(jid);
            }
        }
        return ret;
    }

    public Gee.List<ReactionUsers> get_muc_message_reactions(Account account, ContentItem content_item) {
        QueryBuilder select = db.reaction.select()
                .with(db.reaction.account_id, "=", account.id)
                .with(db.reaction.content_item_id, "=", content_item.id)
                .join_with(db.occupantid, db.occupantid.id, db.reaction.occupant_id)
                .order_by(db.reaction.time, "DESC");

        string? own_occupant_id = stream_interactor.get_module(MucManager.IDENTITY).get_own_occupant_id(account, content_item.jid);

        var ret = new ArrayList<ReactionUsers>();
        var index = new HashMap<string, ReactionUsers>();
        foreach (Row row in select) {
            string emoji_str = row[db.reaction.emojis];

            Jid jid = null;
            if (row[db.occupantid.occupant_id] == own_occupant_id) {
                jid = account.bare_jid;
            } else {
                string nick = row[db.occupantid.last_nick];
                jid = content_item.jid.with_resource(nick);
            }

            foreach (string emoji in emoji_str.split(",")) {
                if (!index.has_key(emoji)) {
                    index[emoji] = new ReactionUsers() { reaction=emoji, jids=new ArrayList<Jid>(Jid.equals_func) };
                    ret.add(index[emoji]);
                }
                index[emoji].jids.add(jid);
            }
        }
        return ret;
    }

    private void on_account_added(Account account) {
        // TODO get time from delays
        stream_interactor.module_manager.get_module(account, Xmpp.Xep.Reactions.Module.IDENTITY).received_reactions.connect((stream, from_jid, message_id, reactions, stanza) => {
            on_reaction_received.begin(account, from_jid, message_id, reactions, stanza);
        });
    }

    private async void on_reaction_received(Account account, Jid from_jid, string message_id, Gee.List<string> reactions, MessageStanza stanza) {
        if (stanza.type_ == MessageStanza.TYPE_GROUPCHAT) {
            // Apply the same restrictions for incoming reactions as we do on sending them
            Conversation muc_conversation = stream_interactor.get_module(ConversationManager.IDENTITY).approx_conversation_for_stanza(from_jid, account.bare_jid, account, MessageStanza.TYPE_GROUPCHAT);
            bool muc_supports_reactions = yield conversation_supports_reactions(muc_conversation);
            if (!muc_supports_reactions) return;
        }

        Message reaction_message = yield stream_interactor.get_module(MessageProcessor.IDENTITY).parse_message_stanza(account, stanza);
        Conversation conversation = stream_interactor.get_module(ConversationManager.IDENTITY).get_conversation_for_message(reaction_message);

        Message? message = get_message_for_reaction(conversation, message_id);
        var reaction_info = new ReactionInfo() { account=account, from_jid=from_jid, reactions=reactions, stanza=stanza, received_time=new DateTime.now() };

        if (message != null) {
            process_reaction_for_message(message.id, reaction_info);
            return;
        }

        // Store reaction infos for later processing after we got the message
        debug("Got reaction for %s but dont have message yet %s", message_id, db.get_jid_id(stanza.from.bare_jid).to_string());
        if (!reaction_infos.has_key(message_id)) {
            reaction_infos[message_id] = new ArrayList<ReactionInfo>();
        }
        reaction_infos[message_id].add(reaction_info);
    }

    private void on_new_message(Message message, Conversation conversation) {
        Gee.List<ReactionInfo>? reaction_info_list = null;
        if (conversation.type_ == Conversation.Type.CHAT) {
            reaction_info_list = reaction_infos[message.stanza_id];
        } else {
            reaction_info_list = reaction_infos[message.server_id];
        }
        if (reaction_info_list == null) return;

        // Check if the (or potentially which) reaction fits the message
        ReactionInfo? reaction_info = null;
        foreach (ReactionInfo info in reaction_info_list) {
            if (!info.account.equals(conversation.account)) return;
            switch (info.stanza.type_) {
                case MessageStanza.TYPE_CHAT:
                    Jid counterpart = message.from.equals_bare(conversation.account.bare_jid) ? info.stanza.from: info.stanza.to;
                    if (message.type_ != Message.Type.CHAT || !counterpart.equals_bare(conversation.counterpart)) continue;
                    break;
                case MessageStanza.TYPE_GROUPCHAT:
                    if (message.type_ != Message.Type.GROUPCHAT || !message.from.equals_bare(conversation.counterpart)) continue;
                    break;
                default:
                    break;
            }

            reaction_info = info;
        }
        if (reaction_info == null) return;
        reaction_info_list.remove(reaction_info);
        if (reaction_info_list.is_empty) {
            if (conversation.type_ == Conversation.Type.GROUPCHAT) {
                reaction_infos.unset(message.server_id);
            } else {
                reaction_infos.unset(message.stanza_id);
            }
        }

        debug("Got message for reaction %s", message.stanza_id);
        process_reaction_for_message(message.id, reaction_info);
    }

    private Message? get_message_for_reaction(Conversation conversation, string message_id) {
        // Query message from a specific account and counterpart. This also makes sure it's a valid reaction for the message.
        if (conversation.type_ == Conversation.Type.CHAT) {
            return stream_interactor.get_module(MessageStorage.IDENTITY).get_message_by_stanza_id(message_id, conversation);
        } else {
            return stream_interactor.get_module(MessageStorage.IDENTITY).get_message_by_server_id(message_id, conversation);
        }
    }

    private void process_reaction_for_message(int message_db_id, ReactionInfo reaction_info) {
        Account account = reaction_info.account;
        MessageStanza stanza = reaction_info.stanza;
        Jid from_jid = reaction_info.from_jid;
        Gee.List<string> reactions = reaction_info.reactions;

        RowOption file_transfer_row = db.file_transfer.select()
                .with(db.file_transfer.account_id, "=", account.id)
                .with(db.file_transfer.info, "=", message_db_id.to_string())
                .single().row(); // TODO better

        var content_item_row = db.content_item.select();

        if (file_transfer_row.is_present()) {
            content_item_row.with(db.content_item.foreign_id, "=", file_transfer_row[db.file_transfer.id])
                    .with(db.content_item.content_type, "=", 2);
        } else {
            content_item_row.with(db.content_item.foreign_id, "=", message_db_id)
                    .with(db.content_item.content_type, "=", 1);
        }
        var content_item_row_opt = content_item_row.single().row();
        if (!content_item_row_opt.is_present()) return;
        int content_item_id = content_item_row_opt[db.content_item.id];

        // Get reaction time
        DateTime? reaction_time = null;
        DelayedDelivery.MessageFlag? delayed_message_flag = DelayedDelivery.MessageFlag.get_flag(stanza);
        if (delayed_message_flag != null) {
            reaction_time = delayed_message_flag.datetime;
        }
        if (reaction_time == null) {
            MessageArchiveManagement.MessageFlag? mam_message_flag = MessageArchiveManagement.MessageFlag.get_flag(stanza);
            if (mam_message_flag != null) reaction_time = mam_message_flag.server_time;
        }
        var time_now = new DateTime.now_local();
        if (reaction_time == null) reaction_time = time_now;
        if (reaction_time.compare(time_now) > 0)  {
            reaction_time = reaction_info.received_time;
        }
        long reaction_time_long = (long) (reaction_time.to_unix() * 1000 + reaction_time.get_microsecond() / 1000);

        // Get current reactions
        string? occupant_id = OccupantIds.get_occupant_id(stanza.stanza);
        Jid? real_jid = stream_interactor.get_module(MucManager.IDENTITY).get_real_jid(from_jid, account);
        if (stanza.type_ == MessageStanza.TYPE_GROUPCHAT && occupant_id == null && real_jid == null) {
            warning("Attempting to add reaction to message w/o knowing occupant id or real jid");
            return;
        }

        ReactionsTime reactions_time = null;
        if (stanza.type_ == MessageStanza.TYPE_GROUPCHAT) {
            reactions_time = get_muc_user_reactions(account, content_item_id, occupant_id, real_jid);
        } else {
            reactions_time = get_chat_user_reactions(account, content_item_id, from_jid);
        }

        if (reaction_time_long <= reactions_time.time) {
            // We already have a more recent reaction
            return;
        }

        // Save reactions
        if (stanza.type_ == MessageStanza.TYPE_GROUPCHAT) {
            save_muc_reactions(account, content_item_id, from_jid, occupant_id, real_jid, reaction_time_long, reactions);
        } else {
            save_chat_reactions(account, from_jid, content_item_id, reaction_time_long, reactions);
        }

        // Notify about reaction changes
        Gee.List<string>? current_reactions = reactions_time.emojis;

        Jid signal_jid = from_jid;
        if (stanza.type_ == MessageStanza.TYPE_GROUPCHAT &&
                signal_jid.equals(stream_interactor.get_module(MucManager.IDENTITY).get_own_jid(from_jid, account))) {
            signal_jid = account.bare_jid;
        }

        foreach (string current_reaction in current_reactions) {
            if (!reactions.contains(current_reaction)) {
                reaction_removed(account, content_item_id, signal_jid, current_reaction);
            }
        }
        foreach (string new_reaction in reactions) {
            if (!current_reactions.contains(new_reaction)) {
                reaction_added(account, content_item_id, signal_jid, new_reaction);
            }
        }

        debug("reactions were: ");
        foreach (string reac in current_reactions) {
            debug(reac);
        }
        debug("reactions new : ");
        foreach (string reac in reactions) {
            debug(reac);
        }
    }

    private void save_chat_reactions(Account account, Jid jid, int content_item_id, long reaction_time, Gee.List<string> reactions) {
        var emoji_builder = new StringBuilder();
        for (int i = 0; i < reactions.size; i++) {
            if (i != 0) emoji_builder.append(",");
            emoji_builder.append(reactions[i]);
        }

        db.reaction.upsert()
                .value(db.reaction.account_id, account.id, true)
                .value(db.reaction.content_item_id, content_item_id, true)
                .value(db.reaction.jid_id, db.get_jid_id(jid), true)
                .value(db.reaction.emojis, emoji_builder.str, false)
                .value(db.reaction.time, reaction_time, false)
                .perform();
    }

    private void save_muc_reactions(Account account, int content_item_id, Jid jid, string? occupant_id, Jid? real_jid, long reaction_time, Gee.List<string> reactions) {
        assert(occupant_id != null || real_jid != null);

        int jid_id = db.get_jid_id(jid);

        var emoji_builder = new StringBuilder();
        for (int i = 0; i < reactions.size; i++) {
            if (i != 0) emoji_builder.append(",");
            emoji_builder.append(reactions[i]);
        }

        var builder = db.reaction.upsert()
                .value(db.reaction.account_id, account.id, true)
                .value(db.reaction.content_item_id, content_item_id, true)
                .value(db.reaction.emojis, emoji_builder.str, false)
                .value(db.reaction.time, reaction_time, false);

        if (real_jid != null) {
            builder.value(db.reaction.jid_id, db.get_jid_id(real_jid), occupant_id == null);
        }

        if (occupant_id != null) {
            RowOption row = db.occupantid.select()
                    .with(db.occupantid.account_id, "=", account.id)
                    .with(db.occupantid.jid_id, "=", jid_id)
                    .with(db.occupantid.occupant_id, "=", occupant_id)
                    .single().row();

            int occupant_db_id = -1;
            if (row.is_present()) {
                occupant_db_id = row[db.occupantid.id];
            } else {
                occupant_db_id = (int)db.occupantid.upsert()
                        .value(db.occupantid.account_id, account.id, true)
                        .value(db.occupantid.jid_id, jid_id, true)
                        .value(db.occupantid.occupant_id, occupant_id, true)
                        .value(db.occupantid.last_nick, jid.resourcepart, false)
                        .perform();
            }
            builder.value(db.reaction.occupant_id, occupant_db_id, true);
        }

        builder.perform();
    }
}

public class Dino.ReactionUsers {
    public string reaction { get; set; }
    public Gee.List<Jid> jids { get; set; }
}

public class Dino.ReactionInfo {
    public Account account { get; set; }
    public Jid from_jid { get; set; }
    public Gee.List<string> reactions { get; set; }
    public MessageStanza stanza { get; set; }
    public DateTime received_time { get; set; }
}
