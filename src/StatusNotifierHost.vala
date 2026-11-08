/*
 * StatusNotifierHost.vala
 * 
 * Manages collection of StatusNotifierItem tray icons
 * Coordinates with StatusNotifierWatcher
 */

public class StatusNotifierHost : Object {
    private StatusNotifierWatcherInterface? watcher;
    private Gee.HashMap<string, TrayIcon> icons;
    private string host_service_name;
    private uint host_name_id = 0;
    private uint fallback_poll_id = 0;
    private Gee.HashSet<string> displayed = new Gee.HashSet<string>();
    
    public signal void icon_added(TrayIcon icon);
    public signal void icon_removed(TrayIcon icon);
    
    public StatusNotifierHost() {
        icons = new Gee.HashMap<string, TrayIcon>();
        host_service_name = "org.kde.StatusNotifierHost-%d".printf(Posix.getpid());
    }
    
    public async void start() {
        try {
            // Own our host service name
            host_name_id = Bus.own_name(
                BusType.SESSION,
                host_service_name,
                BusNameOwnerFlags.NONE,
                null,
                null,
                null
            );

            // Give the bus a moment to register our name
            Timeout.add(100, () => {
                connect_to_watcher.begin();
                return false;
            });

        } catch (Error e) {
            critical("Failed to start StatusNotifierHost: %s", e.message);
        }
    }
    
    private async void connect_to_watcher() {
        try {
            // Connect to the watcher
            watcher = yield Bus.get_proxy<StatusNotifierWatcherInterface>(
                BusType.SESSION,
                "org.kde.StatusNotifierWatcher",
                "/StatusNotifierWatcher",
                DBusProxyFlags.NONE
            );
            
            // Subscribe before reading the initial snapshot.
            watcher.StatusNotifierItemRegistered.connect(on_item_registered);
            watcher.StatusNotifierItemUnregistered.connect(on_item_unregistered);

            try {
                yield watcher.RegisterStatusNotifierHost(host_service_name);
                debug("StatusNotifierHost registered on D-Bus: %s", host_service_name);
                foreach (var item_service in watcher.RegisteredStatusNotifierItems) {
                    on_item_registered(item_service);
                }
            } catch (Error e) {
                // indicator-application implements this method as a failing stub.
                // Its watcher still exposes the registered item list, but does not
                // reliably emit item signals, so read the property directly.
                var remote_error = DBusError.get_remote_error(e);
                if (remote_error != "org.freedesktop.DBus.GLib.ErrorError" ||
                    !e.message.contains("Method invoked for RegisterStatusNotifierHost returned FALSE but did not set error")) {
                    throw e;
                }
                warning("Watcher rejected host registration; polling its item list: %s", e.message);
                yield refresh_items();
                if (fallback_poll_id == 0) {
                    fallback_poll_id = Timeout.add_seconds(2, () => {
                        refresh_items.begin((obj, result) => {
                            try {
                                refresh_items.end(result);
                            } catch (Error poll_error) {
                                warning("Failed to refresh tray items: %s", poll_error.message);
                            }
                        });
                        return Source.CONTINUE;
                    });
                }
            }
            
        } catch (Error e) {
            critical("Failed to connect to StatusNotifierWatcher: %s", e.message);
            // Retry connection after delay
            Timeout.add_seconds(2, () => {
                connect_to_watcher.begin();
                return false;
            });
        }
    }
    
    private async void refresh_items() throws Error {
        var conn = yield Bus.get(BusType.SESSION);
        var reply = yield conn.call(
            "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
            "org.freedesktop.DBus.Properties", "Get",
            new Variant("(ss)", "org.kde.StatusNotifierWatcher", "RegisteredStatusNotifierItems"),
            new VariantType("(v)"), DBusCallFlags.NONE, 5000, null
        );
        Variant boxed;
        reply.get("(v)", out boxed);
        var current = new Gee.HashSet<string>();
        foreach (var service in boxed.get_strv()) {
            current.add(service);
            on_item_registered(service);
        }
        foreach (var service in icons.keys.to_array()) {
            if (!current.contains(service)) on_item_unregistered(service);
        }
    }

    private void on_item_registered(string service) {
        // Don't add duplicates
        if (icons.has_key(service)) {
            debug("StatusNotifierItem already exists, skipping: %s", service);
            return;
        }

        string bus_name;
        string object_path;
        
        // Parse the service string - it can be in multiple formats:
        int first_slash = service.index_of("/");
        if (first_slash > 0) {
            string before_slash = service.substring(0, first_slash);
            int last_colon_before_slash = before_slash.last_index_of(":");
            if (last_colon_before_slash > 0) {
                bus_name = service.substring(0, last_colon_before_slash);
                object_path = service.substring(last_colon_before_slash + 1);
                debug("Parsed Ayatana format: bus='%s', path='%s'", bus_name, object_path);
            } else {
                bus_name = service.substring(0, first_slash);
                object_path = service.substring(first_slash);
                debug("Parsed bus/path format: bus='%s', path='%s'", bus_name, object_path);
            }
        } else if (service.has_prefix("/")) {
            debug("Ignored bare object path: %s", service);
            return;
        } else {
            bus_name = service;
            object_path = "/StatusNotifierItem";
            debug("Parsed standard SNI: bus='%s', path='%s'", bus_name, object_path);
        }
        
        var icon = new TrayIcon(service, bus_name, object_path);
        icons.set(service, icon);
        icon.ready.connect(() => {
            if (icons.get(service) != icon) return;
            displayed.add(service);
            icon_added(icon);
        });

        icon.removed.connect(() => {
            if (icons.get(service) == icon) on_item_unregistered(service);
        });
        
        icon.initialize.begin();
    }
    
    private void on_item_unregistered(string service) {
        debug("StatusNotifierItem unregistered: %s", service);
        var icon = icons.get(service);
        if (icon != null) {
            icons.unset(service);
            if (displayed.remove(service)) icon_removed(icon);
        }
    }
    
    public void stop() {
        if (host_name_id != 0) {
            Bus.unown_name(host_name_id);
            host_name_id = 0;
        }
        
        if (fallback_poll_id != 0) {
            Source.remove(fallback_poll_id);
            fallback_poll_id = 0;
        }
        icons.clear();
        displayed.clear();
    }
}

