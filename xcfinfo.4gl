-- xcfinfo — Genero Application Server configuration inspector
--
-- Reads the GAS server configuration (as.xcf) and a Genero application XCF
-- file to compute and display two pieces of information:
--
--   1. The browser URL needed to launch the application through the GAS
--      dispatcher (protocol, host, port, group path, and app name).
--
--   2. The DVM environment variable set that the GAS execution component
--      will inject when it runs the application (merged from as.xcf and the
--      app XCF, with APPEND/PREPEND concat rules applied).
--

#+ xcfinfo — Genero Application Server configuration inspector.
#+
#+ Reads the GAS server configuration (as.xcf) and a Genero application XCF file
#+ to compute and display the browser URL for launching the application through the
#+ GAS dispatcher, and the DVM environment variable set that the execution component
#+ will inject at runtime.
#+
#+ Usage:
#+   fglrun xcfinfo <app.xcf> [options]
#+
#+ Required:
#+   <app.xcf>           Path to the Genero application XCF file.
#+
#+ Options:
#+   --url <host>        Override the hostname in the browser URL (default: localhost).
#+
#+   --no-env            Suppress the environment variable output.
#+
#+   --ua-groups <file>  Use this APPLICATION_GROUPS XML file to resolve the
#+                       application group and URL path instead of querying the
#+                       running dispatcher. Mutually exclusive with --ws-groups.
#+
#+   --ws-groups <file>  Use this SERVICE_GROUPS XML file to resolve the
#+                       service group and URL path instead of querying the
#+                       running dispatcher. Mutually exclusive with --ua-groups.
#+
#+   --as-config <file>  Use this file as the GAS server configuration instead
#+                       of the default $FGLASDIR/etc/as.xcf. Useful when
#+                       inspecting a non-active GAS installation or a staging
#+                       configuration file.
#+
#+   --http              Use http:// in the browser URL (default).
#+   --https             Use https:// in the browser URL.
#+
#+   --port <port>       Override the port in the browser URL (default: from as.xcf).
#+
#+   --verbose           Print diagnostic information about each processing step.

IMPORT FGL xcfinfo_lib

#+ Entry point: parse command-line arguments and delegate processing to xcfinfo_lib.run().
FUNCTION main()
    DEFINE l_xcf_file       STRING   # required: path to the application XCF file
    DEFINE l_as_config      STRING   # --as-config override (NULL → use $FGLASDIR/etc/as.xcf)
    DEFINE l_ua_groups      STRING   # --ua-groups file (NULL → use running dispatcher)
    DEFINE l_ws_groups      STRING   # --ws-groups file (NULL → use running dispatcher)
    DEFINE l_protocol       STRING   # --http/--https (NULL → default "http" in lib)
    DEFINE l_host           STRING   # --url value (NULL → default "localhost" in lib)
    DEFINE l_port_override  STRING   # --port value (NULL → from as.xcf in lib)
    DEFINE l_show_env       BOOLEAN  # FALSE if --no-env; TRUE by default
    DEFINE l_verbose        BOOLEAN  # TRUE if --verbose; NULL → default FALSE in lib
    DEFINE i                INTEGER  # argument loop counter

    LET l_show_env = TRUE
    LET i = 1
    WHILE i <= num_args()
        CASE arg_val(i)
            WHEN "--url"
                LET i = i + 1
                IF i <= num_args() THEN
                    LET l_host = arg_val(i)
                END IF
            WHEN "--no-env"
                LET l_show_env = FALSE
            WHEN "--ua-groups"
                LET i = i + 1
                IF i <= num_args() THEN
                    VAR _ua_file STRING = arg_val(i)
                    DISPLAY SFMT("UA groups: %1", _ua_file)
                    LET l_ua_groups = _ua_file
                END IF
            WHEN "--ws-groups"
                LET i = i + 1
                IF i <= num_args() THEN
                    VAR _ws_file STRING = arg_val(i)
                    DISPLAY SFMT("WS groups: %1", _ws_file)
                    LET l_ws_groups = _ws_file
                END IF
            WHEN "--as-config"
                LET i = i + 1
                IF i <= num_args() THEN
                    LET l_as_config = arg_val(i)
                END IF
            WHEN "--http"
                LET l_protocol = "http"
            WHEN "--https"
                LET l_protocol = "https"
            WHEN "--port"
                LET i = i + 1
                IF i <= num_args() THEN
                    LET l_port_override = arg_val(i)
                END IF
            WHEN "--verbose"
                LET l_verbose = TRUE
            OTHERWISE
                IF l_xcf_file IS NULL THEN
                    LET l_xcf_file = arg_val(i)
                END IF
        END CASE
        LET i = i + 1
    END WHILE

    IF l_xcf_file IS NULL THEN
        DISPLAY "Usage: fglrun xcfinfo <app.xcf> [--no-env] [--ua-groups <file>|--ws-groups <file>] [--as-config <file>] [--http|--https] [--url <host>] [--port <port>] [--verbose]"
        EXIT PROGRAM 1
    END IF

    IF l_ua_groups IS NOT NULL AND l_ws_groups IS NOT NULL THEN
        DISPLAY "Error: --ua-groups and --ws-groups are mutually exclusive"
        EXIT PROGRAM 1
    END IF

    CALL xcfinfo_lib.inspect_app(l_xcf_file, l_as_config, l_ua_groups, l_ws_groups,
                                 l_protocol, l_host, l_port_override, l_show_env, l_verbose)
END FUNCTION
