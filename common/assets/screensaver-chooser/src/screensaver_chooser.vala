using GLib;
using Gtk;
using Peas;
using Singularity;

[ModuleInit]
public void peas_register_types (TypeModule module) {
    var object_module = module as Peas.ObjectModule;
    object_module.register_extension_type (typeof (Singularity.Plugin), typeof (ScreensaverChooserPlugin));
}

public class SaverEntry : Object {
    public string id { get; construct; }
    public string title { get; construct; }
    public string group_name { get; construct; }

    public SaverEntry (string id, string title, string group_name) {
        Object (id: id, title: title, group_name: group_name);
    }
}

public class ScreensaverChooserPlugin : Object, Singularity.Plugin {
    private const string CATALOG_PATH = "/usr/share/ncz-screensaver-chooser/hacks.tsv";
    private const string PREVIEW_PATH = "/usr/share/ncz-screensaver-chooser/previews";
    private GLib.Settings? settings;
    private Gee.ArrayList<SaverEntry> catalog = new Gee.ArrayList<SaverEntry> ();
    private ComboBoxText? mode;
    private ComboBoxText? group_filter;
    private ListBox? savers;
    private Label? count_label;
    private Picture? preview;
    private Label? preview_note;
    private SaverEntry? selected;

    public void activate (PluginContext context) {
        settings = new GLib.Settings ("dev.ncz.screensaver");
        load_catalog (CATALOG_PATH);
    }

    public void deactivate () {
        settings = null;
        catalog.clear ();
        mode = null;
        group_filter = null;
        savers = null;
        count_label = null;
        preview = null;
        preview_note = null;
        selected = null;
    }

    public Gtk.Widget? get_settings_widget () {
        if (settings == null)
            return new Label ("Screensaver settings are not available.");

        var root = new Box (Orientation.VERTICAL, 12);
        root.margin_top = 12;
        root.margin_bottom = 12;
        root.margin_start = 12;
        root.margin_end = 12;

        var intro = new Label ("Choose one screensaver or rotate through a group or the full catalogue.");
        intro.halign = Align.START;
        intro.wrap = true;
        root.append (intro);

        var controls = new Grid ();
        controls.column_spacing = 12;
        controls.row_spacing = 8;
        mode = new ComboBoxText ();
        mode.append ("off", "Off");
        mode.append ("one", "Specific screensaver");
        mode.append ("group", "Random within group");
        mode.append ("all", "Random across all");
        group_filter = new ComboBoxText ();
        group_filter.append ("Black Hole Simulation", "Black Hole Simulation");
        group_filter.append ("hyprsaver", "hyprsaver");
        group_filter.append ("xshadertoy", "xshadertoy");
        group_filter.append ("Classics", "Classics");
        group_filter.active = 0;
        controls.attach (left_label ("Mode"), 0, 0);
        controls.attach (mode, 1, 0);
        controls.attach (left_label ("Group"), 2, 0);
        controls.attach (group_filter, 3, 0);

        var idle = new SpinButton.with_range (1, 240, 1);
        idle.value = settings.get_int ("hack-idle-delay") / 60;
        idle.value_changed.connect (() => settings.set_int ("hack-idle-delay", (int) idle.value * 60));
        controls.attach (left_label ("Start after (minutes)"), 0, 1);
        controls.attach (idle, 1, 1);

        var cycle = new SpinButton.with_range (1, 240, 1);
        cycle.value = settings.get_int ("cycle-delay") / 60;
        cycle.value_changed.connect (() => settings.set_int ("cycle-delay", (int) cycle.value * 60));
        controls.attach (left_label ("Rotate after (minutes)"), 2, 1);
        controls.attach (cycle, 3, 1);
        root.append (controls);

        var content = new Paned (Orientation.HORIZONTAL);
        content.position = 360;
        content.vexpand = true;
        var left = new Box (Orientation.VERTICAL, 6);
        count_label = new Label ("");
        count_label.halign = Align.START;
        count_label.add_css_class ("dim-label");
        left.append (count_label);
        savers = new ListBox ();
        savers.selection_mode = SelectionMode.SINGLE;
        savers.add_css_class ("boxed-list");
        savers.row_selected.connect (on_selected);
        var scroll = new ScrolledWindow ();
        scroll.vexpand = true;
        scroll.set_child (savers);
        left.append (scroll);
        content.start_child = left;

        var right = new Box (Orientation.VERTICAL, 8);
        right.margin_start = 12;
        preview = new Picture ();
        preview.content_fit = ContentFit.CONTAIN;
        preview.hexpand = true;
        preview.vexpand = true;
        preview_note = new Label ("Select a screensaver to see its captured preview.");
        preview_note.wrap = true;
        var preview_button = new Button.with_label ("Preview now");
        preview_button.clicked.connect (launch_preview);
        right.append (preview);
        right.append (preview_note);
        right.append (preview_button);
        content.end_child = right;
        root.append (content);

        set_mode_from_settings ();
        mode.changed.connect (apply_mode);
        group_filter.changed.connect (() => {
            rebuild_list ();
            if (mode.active_id == "group")
                apply_mode ();
        });
        rebuild_list ();
        select_configured_saver ();
        return root;
    }

    private Label left_label (string text) {
        var label = new Label (text);
        label.halign = Align.START;
        return label;
    }

    private void load_catalog (string path) {
        catalog.clear ();
        try {
            string data;
            FileUtils.get_contents (path, out data);
            foreach (string line in data.split ("\n")) {
                if (line == "" || line.has_prefix ("#"))
                    continue;
                string[] fields = line.split ("\t");
                if (fields.length == 4)
                    catalog.add (new SaverEntry (fields[0], fields[1], fields[2]));
            }
        } catch (Error error) {
            warning ("Cannot load screensaver catalog: %s", error.message);
        }
    }

    private void set_mode_from_settings () {
        string saved_mode = settings.get_string ("mode");
        if (saved_mode == "off" || saved_mode == "one") {
            mode.active_id = saved_mode;
            return;
        }
        string[] random_ids = settings.get_strv ("random-hacks");
        mode.active_id = random_ids.length == catalog.size ? "all" : "group";
        if (random_ids.length > 0) {
            SaverEntry? entry = find_entry (random_ids[0]);
            if (entry != null)
                group_filter.active_id = entry.group_name;
        }
    }

    private void apply_mode () {
        string selected_mode = mode.active_id ?? "off";
        if (selected_mode == "off") {
            settings.set_string ("mode", "off");
        } else if (selected_mode == "one") {
            settings.set_string ("mode", "one");
            if (selected != null)
                settings.set_string ("hack-id", selected.id);
        } else {
            settings.set_string ("mode", "random");
            var ids = new Gee.ArrayList<string> ();
            foreach (SaverEntry entry in catalog) {
                if (selected_mode == "all" || entry.group_name == group_filter.active_id)
                    ids.add (entry.id);
            }
            settings.set_strv ("random-hacks", ids.to_array ());
        }
    }

    private void rebuild_list () {
        Widget? child;
        while ((child = savers.get_first_child ()) != null)
            savers.remove (child);
        string active_group = group_filter.active_id ?? "Black Hole Simulation";
        int visible = 0;
        foreach (SaverEntry entry in catalog) {
            if (entry.group_name != active_group)
                continue;
            var row = new ListBoxRow ();
            var label = new Label (entry.title);
            label.halign = Align.START;
            label.margin_top = 7;
            label.margin_bottom = 7;
            label.margin_start = 9;
            label.margin_end = 9;
            row.set_child (label);
            row.set_data<SaverEntry> ("saver", entry);
            savers.append (row);
            visible++;
        }
        count_label.label = "%d screensavers in %s".printf (visible, active_group);
    }

    private void select_configured_saver () {
        string configured = settings.get_string ("hack-id");
        for (Widget? child = savers.get_first_child (); child != null; child = child.get_next_sibling ()) {
            var row = child as ListBoxRow;
            SaverEntry? entry = row.get_data<SaverEntry> ("saver");
            if (entry != null && entry.id == configured) {
                savers.select_row (row);
                return;
            }
        }
    }

    private SaverEntry? find_entry (string id) {
        foreach (SaverEntry entry in catalog)
            if (entry.id == id)
                return entry;
        return null;
    }

    private void on_selected (ListBoxRow? row) {
        if (row == null)
            return;
        selected = row.get_data<SaverEntry> ("saver");
        if (selected == null)
            return;
        if (mode.active_id == "one")
            settings.set_string ("hack-id", selected.id);
        string path = "%s/%s.png".printf (PREVIEW_PATH, selected.id);
        if (FileUtils.test (path, FileTest.EXISTS)) {
            preview.set_filename (path);
            preview_note.label = "%s - captured on an NCZ-OS Wayland session".printf (selected.title);
        } else {
            preview.set_paintable (null);
            preview_note.label = "%s has no packaged capture. Use Preview now to run it on this display.".printf (selected.title);
        }
    }

    private void launch_preview () {
        if (selected == null)
            return;
        try {
            Process.spawn_command_line_async ("/usr/libexec/ncz-screensaver-run --preview %s".printf (GLib.Shell.quote (selected.id)));
        } catch (SpawnError error) {
            preview_note.label = "Could not launch preview: %s".printf (error.message);
        }
    }
}
