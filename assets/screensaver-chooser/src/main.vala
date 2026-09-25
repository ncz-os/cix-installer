using Gtk;
using GLib;

public class Hack : Object {
    public string id { get; construct; }
    public string title { get; construct; }
    public string family { get; construct; }
    public string theme { get; construct; }

    public Hack (string id, string title, string family, string theme) {
        Object (id: id, title: title, family: family, theme: theme);
    }
}

public class ChooserWindow : Gtk.ApplicationWindow {
    private GLib.Settings settings;
    private ListBox hacks;
    private ComboBoxText family_filter;
    private ComboBoxText theme_filter;
    private Picture preview;
    private Label preview_note;
    private Label count_label;
    private Hack? selected;
    private Gee.ArrayList<Hack> catalog = new Gee.ArrayList<Hack> ();

    public ChooserWindow (Gtk.Application app) {
        Object (application: app, title: "Screensaver & Lock");
        set_default_size (980, 680);
        settings = new GLib.Settings ("dev.ncz.screensaver");
        load_catalog ("/usr/share/ncz-screensaver-chooser/hacks.tsv");

        var root = new Box (Orientation.VERTICAL, 12);
        root.margin_top = root.margin_bottom = 16;
        root.margin_start = root.margin_end = 16;
        set_child (root);

        var heading = new Label ("NCZ-OS Screensaver Chooser");
        heading.add_css_class ("title-1");
        heading.halign = Align.START;
        root.append (heading);

        var modes = new Box (Orientation.HORIZONTAL, 8);
        var off = new CheckButton.with_label ("Off");
        var one = new CheckButton.with_label ("Only one");
        var random = new CheckButton.with_label ("Random rotation");
        one.group = off;
        random.group = off;
        string mode = settings.get_string ("mode");
        if (mode == "one") one.active = true;
        else if (mode == "random") random.active = true;
        else off.active = true;
        off.toggled.connect (() => { if (off.active) settings.set_string ("mode", "off"); });
        one.toggled.connect (() => { if (one.active) settings.set_string ("mode", "one"); });
        random.toggled.connect (() => { if (random.active) settings.set_string ("mode", "random"); });
        modes.append (off); modes.append (one); modes.append (random);
        root.append (modes);

        var paned = new Paned (Orientation.HORIZONTAL);
        paned.position = 390;
        paned.vexpand = true;
        root.append (paned);

        var left = new Box (Orientation.VERTICAL, 8);
        family_filter = new ComboBoxText ();
        theme_filter = new ComboBoxText ();
        family_filter.append ("all", "All source families");
        family_filter.append ("base", "Base / Round ports");
        family_filter.append ("hyprsaver", "Hyprsaver shaders");
        family_filter.append ("rss", "RSS-SDL2-GLES2");
        theme_filter.append ("all", "All themes");
        string[] themes = { "Abstract & Psychedelic", "Geometry & Fractals", "Nature & Organic", "Particles & Physics", "Space & Sci-Fi", "Machines & Objects", "Text & Data" };
        foreach (string theme in themes)
            theme_filter.append (theme, theme);
        family_filter.active_id = "all";
        theme_filter.active_id = "all";
        family_filter.changed.connect (rebuild_list);
        theme_filter.changed.connect (rebuild_list);
        var filters = new Box (Orientation.HORIZONTAL, 6);
        family_filter.hexpand = true; theme_filter.hexpand = true;
        filters.append (family_filter); filters.append (theme_filter);
        left.append (filters);
        count_label = new Label (""); count_label.halign = Align.START;
        count_label.add_css_class ("dim-label"); left.append (count_label);
        hacks = new ListBox (); hacks.selection_mode = SelectionMode.SINGLE;
        hacks.add_css_class ("boxed-list");
        hacks.row_selected.connect (on_selected);
        var scroll = new ScrolledWindow (); scroll.vexpand = true; scroll.set_child (hacks);
        left.append (scroll); paned.start_child = left;

        var right = new Box (Orientation.VERTICAL, 10);
        right.margin_start = 16;
        preview = new Picture (); preview.vexpand = true; preview.hexpand = true;
        preview.content_fit = ContentFit.CONTAIN;
        preview_note = new Label ("Select a screensaver to see its captured preview.");
        preview_note.wrap = true;
        var preview_button = new Button.with_label ("Preview now");
        preview_button.clicked.connect (launch_preview);
        right.append (preview); right.append (preview_note); right.append (preview_button);
        paned.end_child = right;

        var timing = new Grid (); timing.column_spacing = 12; timing.row_spacing = 8;
        var idle = new SpinButton.with_range (1, 240, 1);
        var cycle = new SpinButton.with_range (1, 240, 1);
        var lock_delay = new SpinButton.with_range (0, 240, 1);
        var lock_toggle = new Switch ();
        idle.value = settings.get_int ("hack-idle-delay") / 60;
        cycle.value = settings.get_int ("cycle-delay") / 60;
        lock_delay.value = settings.get_int ("lock-delay") / 60;
        lock_toggle.active = settings.get_boolean ("lock-enabled");
        idle.value_changed.connect (() => settings.set_int ("hack-idle-delay", (int) idle.value * 60));
        cycle.value_changed.connect (() => settings.set_int ("cycle-delay", (int) cycle.value * 60));
        lock_delay.value_changed.connect (() => settings.set_int ("lock-delay", (int) lock_delay.value * 60));
        lock_toggle.notify["active"].connect (() => settings.set_boolean ("lock-enabled", lock_toggle.active));
        timing.attach (new Label ("Start after (minutes)"), 0, 0); timing.attach (idle, 1, 0);
        timing.attach (new Label ("Rotate after (minutes)"), 2, 0); timing.attach (cycle, 3, 0);
        timing.attach (new Label ("Lock after screensaver"), 4, 0); timing.attach (lock_toggle, 5, 0);
        timing.attach (new Label ("Lock delay (minutes)"), 6, 0); timing.attach (lock_delay, 7, 0);
        root.append (timing);
        rebuild_list ();
    }

    private void load_catalog (string path) {
        try {
            string data; FileUtils.get_contents (path, out data);
            foreach (string line in data.split ("\n")) {
                if (line == "" || line.has_prefix ("#")) continue;
                string[] f = line.split ("\t");
                if (f.length == 4) catalog.add (new Hack (f[0], f[1], f[2], f[3]));
            }
        } catch (Error e) { warning ("Cannot load screensaver catalog: %s", e.message); }
    }

    private void rebuild_list () {
        Widget? child;
        while ((child = hacks.get_first_child ()) != null) hacks.remove (child);
        string family = family_filter.active_id ?? "all";
        string theme = theme_filter.active_id ?? "all";
        int visible = 0;
        foreach (Hack hack in catalog) {
            if (family != "all" && hack.family != family) continue;
            if (theme != "all" && hack.theme != theme) continue;
            var row = new ListBoxRow ();
            var box = new Box (Orientation.HORIZONTAL, 8);
            box.margin_top = box.margin_bottom = 7; box.margin_start = box.margin_end = 9;
            var enabled = new CheckButton ();
            enabled.tooltip_text = "Include in random rotation";
            enabled.active = random_contains (hack.id);
            enabled.toggled.connect (() => update_random (hack.id, enabled.active));
            var labels = new Box (Orientation.VERTICAL, 2);
            var name = new Label (hack.title); name.halign = Align.START; name.add_css_class ("heading");
            var detail = new Label ("%s  -  %s".printf (family_title (hack.family), hack.theme));
            detail.halign = Align.START; detail.add_css_class ("dim-label");
            labels.append (name); labels.append (detail);
            box.append (enabled); box.append (labels); row.set_child (box); row.set_data<Hack> ("hack", hack);
            hacks.append (row); visible++;
        }
        count_label.label = "%d of %d screensavers".printf (visible, catalog.size);
    }

    private bool random_contains (string id) {
        foreach (string current in settings.get_strv ("random-hacks"))
            if (current == id) return true;
        return false;
    }

    private void update_random (string id, bool enabled) {
        var next = new Gee.ArrayList<string> ();
        foreach (string current in settings.get_strv ("random-hacks"))
            if (current != id) next.add (current);
        if (enabled) next.add (id);
        settings.set_strv ("random-hacks", next.to_array ());
    }

    private string family_title (string family) {
        if (family == "hyprsaver") return "Hyprsaver";
        if (family == "rss") return "RSS-SDL2-GLES2";
        return "Base / Round ports";
    }

    private void on_selected (ListBoxRow? row) {
        if (row == null) return;
        selected = row.get_data<Hack> ("hack");
        if (selected == null) return;
        settings.set_string ("hack-id", selected.id);
        string file = "/usr/share/ncz-screensaver-chooser/previews/%s.png".printf (selected.id);
        if (FileUtils.test (file, FileTest.EXISTS)) {
            preview.set_filename (file);
            preview_note.label = "%s - captured on a real NCZ-OS Wayland session".printf (selected.title);
        } else {
            preview.set_paintable (null);
            preview_note.label = "%s has no packaged capture yet. Use Preview now to run it on this display.".printf (selected.title);
        }
    }

    private void launch_preview () {
        if (selected == null) return;
        try { Process.spawn_command_line_async ("/usr/libexec/ncz-screensaver-run --preview %s".printf (Shell.quote (selected.id))); }
        catch (SpawnError e) { preview_note.label = "Could not launch preview: %s".printf (e.message); }
    }
}

public class ChooserApp : Gtk.Application {
    public ChooserApp () { Object (application_id: "dev.ncz.ScreensaverChooser"); }
    protected override void activate () {
        var window = active_window ?? new ChooserWindow (this);
        window.present ();
    }
}

int main (string[] args) { return new ChooserApp ().run (args); }
