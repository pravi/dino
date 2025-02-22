using Gee;
using Gdk;
using Gtk;

using Dino.Entities;

namespace Dino.Ui {

public class MainWindow : Gtk.Window {

    public signal void conversation_selected(Conversation conversation);

    public new string? title { get; set; }
    public string? subtitle { get; set; }

    public WelcomePlaceholder welcome_placeholder = new WelcomePlaceholder();
    public NoAccountsPlaceholder accounts_placeholder = new NoAccountsPlaceholder();
    public ConversationView conversation_view;
    public ConversationSelector conversation_selector;
    public ConversationTitlebar conversation_titlebar;
    public Widget conversation_list_titlebar;
    public HeaderBar placeholder_headerbar = new HeaderBar() { show_title_buttons=true };
    public Box box = new Box(Orientation.VERTICAL, 0) { orientation=Orientation.VERTICAL };
    public Paned headerbar_paned = new Paned(Orientation.HORIZONTAL) { resize_start_child=false, shrink_start_child=false, shrink_end_child=false };
    public Paned paned;
    public Revealer search_revealer;
    public GlobalSearch global_search;
    private Stack stack = new Stack();
    private Stack left_stack;
    private Stack right_stack;

    private StreamInteractor stream_interactor;
    private Database db;
    private Config config;

    class construct {
        var shortcut = new Shortcut(new KeyvalTrigger(Key.F, ModifierType.CONTROL_MASK), new CallbackAction((widget, args) => {
            ((MainWindow) widget).search_revealer.reveal_child = true;
            return false;
        }));
        add_shortcut(shortcut);
    }

    public MainWindow(Application application, StreamInteractor stream_interactor, Database db, Config config) {
        Object(application : application);
        this.stream_interactor = stream_interactor;
        this.db = db;
        this.config = config;

        this.title = "Dino";

        this.add_css_class("dino-main");

        Gtk.Settings.get_default().notify["gtk-decoration-layout"].connect(set_window_buttons);
        ((Widget)this).realize.connect(set_window_buttons);
        ((Widget)this).realize.connect(restore_window_size);

        setup_headerbar();
        setup_unified();
        setup_stack();

        paned.bind_property("position", headerbar_paned, "position", BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL);
    }

    private void setup_unified() {
        Builder builder = new Builder.from_resource("/im/dino/Dino/unified_main_content.ui");
        paned = (Paned) builder.get_object("paned");
        box.append(paned);
        left_stack = (Stack) builder.get_object("left_stack");
        right_stack = (Stack) builder.get_object("right_stack");
        conversation_view = (ConversationView) builder.get_object("conversation_view");
        search_revealer = (Revealer) builder.get_object("search_revealer");
        conversation_selector = ((ConversationSelector) builder.get_object("conversation_list")).init(stream_interactor);

        Frame search_frame = (Frame) builder.get_object("search_frame");
        global_search = new GlobalSearch(stream_interactor);
        search_frame.set_child(global_search.get_widget());

        Image conversation_list_placeholder_image = (Image) builder.get_object("conversation_list_placeholder_image");
        conversation_list_placeholder_image.set_from_pixbuf(new Pixbuf.from_resource("/im/dino/Dino/dino-conversation-list-placeholder-arrow.svg"));
    }

    private void setup_headerbar() {
        if (Util.use_csd()) {
            conversation_list_titlebar = get_conversation_list_titlebar_csd();
            conversation_titlebar = new ConversationTitlebarCsd();
        } else {
            conversation_list_titlebar = new ConversationListTitlebar();
            conversation_titlebar = new ConversationTitlebarNoCsd();
            box.append(headerbar_paned);
        }
        headerbar_paned.set_start_child(conversation_list_titlebar);
        headerbar_paned.set_end_child(conversation_titlebar.get_widget());
    }

    private void set_window_buttons() {
        if (!Util.use_csd()) return;
        Gtk.Settings? gtk_settings = Gtk.Settings.get_default();
        if (gtk_settings == null) return;

        string[] buttons = gtk_settings.gtk_decoration_layout.split(":");
        HeaderBar conversation_headerbar = this.conversation_titlebar.get_widget() as HeaderBar;
        conversation_headerbar.decoration_layout = ((buttons.length == 2) ? ":" + buttons[1] : "");
        HeaderBar conversation_list_headerbar = this.conversation_list_titlebar as HeaderBar;
        conversation_list_headerbar.decoration_layout = buttons[0] + ":";
    }

    private void setup_stack() {
        stack.add_named(box, "main");
        stack.add_named(welcome_placeholder, "welcome_placeholder");
        stack.add_named(accounts_placeholder, "accounts_placeholder");
        set_child(stack);
    }

    public enum StackState {
        CLEAN_START,
        NO_ACTIVE_ACCOUNTS,
        NO_ACTIVE_CONVERSATIONS,
        CONVERSATION
    }

    public void set_stack_state(StackState stack_state) {
        if (stack_state == StackState.CONVERSATION) {
            left_stack.set_visible_child_name("content");
            right_stack.set_visible_child_name("content");

            stack.set_visible_child_name("main");
            if (Util.use_csd()) {
                set_titlebar(headerbar_paned);
            }
        } else if (stack_state == StackState.CLEAN_START || stack_state == StackState.NO_ACTIVE_ACCOUNTS) {
            if (stack_state == StackState.CLEAN_START) {
                stack.set_visible_child_name("welcome_placeholder");
            } else if (stack_state == StackState.NO_ACTIVE_ACCOUNTS) {
                stack.set_visible_child_name("accounts_placeholder");
            }
            if (Util.use_csd()) {
                set_titlebar(placeholder_headerbar);
            }
        } else if (stack_state == StackState.NO_ACTIVE_CONVERSATIONS) {
            stack.set_visible_child_name("main");
            left_stack.set_visible_child_name("placeholder");
            right_stack.set_visible_child_name("placeholder");
            if (Util.use_csd()) {
                set_titlebar(headerbar_paned);
            }
        }
    }

    public void loop_conversations(bool backwards) {
        conversation_selector.loop_conversations(backwards);
    }

    public void restore_window_size() {
        Gdk.Display? display = Gdk.Display.get_default();
        if (display != null) {
            Gdk.Surface? surface = get_surface();
            Gdk.Monitor? monitor = display.get_monitor_at_surface(surface);

            if (monitor != null &&
                    config.window_width <= monitor.geometry.width &&
                    config.window_height <= monitor.geometry.height) {
                set_default_size(config.window_width, config.window_height);
            }
        }
        if (config.window_maximize) {
            maximize();
        }

        ((Widget)this).unrealize.connect(() => {
            save_window_size();
            config.window_maximize = this.maximized;
        });
    }

    public void save_window_size() {
        if (this.maximized) return;

        Gdk.Display? display = get_display();
        Gdk.Surface? surface = get_surface();
        if (display != null && surface != null) {
            Gdk.Monitor monitor = display.get_monitor_at_surface(surface);

            // Only store if the values have changed and are reasonable-looking.
            if (config.window_width != default_width && default_width > 0 && default_width <= monitor.geometry.width) {
                config.window_width = default_width;
            }
            if (config.window_height != default_height && default_height > 0 && default_height <= monitor.geometry.height) {
                config.window_height = default_height;
            }
        }
    }
}

public class WelcomePlaceholder : MainWindowPlaceholder {
    public WelcomePlaceholder() {
        title_label.label = _("Welcome to Dino!");
        label.label = _("Sign in or create an account to get started.");
        primary_button.label = _("Set up account");
        title_label.visible = true;
        secondary_button.visible = false;
    }
}

public class NoAccountsPlaceholder : MainWindowPlaceholder {
    public NoAccountsPlaceholder() {
        title_label.label = _("No active accounts");
        primary_button.label = _("Manage accounts");
        title_label.visible = true;
        label.visible = false;
        secondary_button.visible = false;
    }
}

[GtkTemplate (ui = "/im/dino/Dino/unified_window_placeholder.ui")]
public class MainWindowPlaceholder : Box {
    [GtkChild] public unowned Label title_label;
    [GtkChild] public unowned Label label;
    [GtkChild] public unowned Button primary_button;
    [GtkChild] public unowned Button secondary_button;
}

}
