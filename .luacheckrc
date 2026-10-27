std = "luajit"

globals = {
    "G_defaults",
    "G_reader_settings",
    "G_reader_ui",
}

-- KOReader callbacks intentionally leave some arguments unused, and a few
-- compatibility branches are deliberately empty.
ignore = {
    "212", -- unused argument
    "213", -- unused loop variable
    "581", -- preserve explicit boolean expressions used by menu callbacks
}

max_line_length = false

files["weread/lib/client.lua"] = {
    ignore = { "211/_status" },
}

files["weread/lib/content.lua"] = {
    ignore = {
        "143/table", -- table.unpack or unpack (LuaJIT/5.1 compatibility)
        "211/normalize_void_elements",
        "211/_headers",
    },
}

files["weread/lib/downloader.lua"] = {
    ignore = { "311/ok" },
}

files["weread/lib/external_annotations.lua"] = {
    ignore = { "211/_start" },
}

files["weread/lib/read_report.lua"] = {
    ignore = { "211/_elapsed" },
}

files["weread/lib/i18n.lua"] = {
    -- Translation catalogs intentionally repeat a key in two grouped sections.
    ignore = { "314" },
}

files["weread/lib/plugin_util.lua"] = {
    ignore = { "143/table" },
}

files["weread/lib/progress_sync.lua"] = {
    ignore = {
        "211/_reason",
        "231/_index",
    },
}

files["weread/lib/protocol.lua"] = {
    ignore = { "311/width" },
}

files["weread/lib/reader_lifecycle.lua"] = {
    ignore = {
        "211/current_ch",
        "211/_started",
        "211/_title",
    },
}

files["weread/ui/annotations_controller.lua"] = {
    ignore = {
        "211/Annotations",
        "211/_current_idx",
    },
}

files["weread/ui/reader_navigation.lua"] = {
    ignore = { "211/current_ch" },
}

files["spec/scan_spec.lua"] = {
    ignore = { "211/d_added" },
}

-- Specs replace standard functions with fakes and reuse fixture names.
files["spec/client_spec.lua"] = {
    ignore = { "311/err" },
}

files["spec/qr_login_spec.lua"] = {
    ignore = { "421/login" },
}

files["spec/progress_sync_spec.lua"] = {
    ignore = { "431/position", "431/remote", "431/checks" },
}

files["spec/read_report_progress_spec.lua"] = {
    ignore = { "211/_title", "231/_a", "311/accepted" },
}

files["spec/remove_book_dir_spec.lua"] = {
    ignore = { "122/os" },
}

files["spec/koreader/*.lua"] = {
    globals = {
        "describe",
        "setup",
        "it",
        "disable_plugins",
        "load_plugin",
    },
}
