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
-- Usage:
--   fglrun xcfinfo <app.xcf> [options]
--
-- Required:
--   <app.xcf>           Path to the Genero application XCF file.
--
-- Options:
--   --url               Print the GAS browser URL for the application.
--                       (default: on)
--   --no-url            Suppress the browser URL output.
--
--   --env               Print the merged DVM environment variables.
--                       (default: on)
--   --no-env            Suppress the environment variable output.
--
--   --ua-groups <file>  Use this APPLICATION_GROUPS XML file to resolve the
--                       application group and URL path instead of querying the
--                       running dispatcher. Mutually exclusive with --ws-groups.
--
--   --ws-groups <file>  Use this SERVICE_GROUPS XML file to resolve the
--                       service group and URL path instead of querying the
--                       running dispatcher. Mutually exclusive with --ua-groups.
--
--   --as-config <file>  Use this file as the GAS server configuration instead
--                       of the default $FGLASDIR/etc/as.xcf. Useful when
--                       inspecting a non-active GAS installation or a staging
--                       configuration file.

IMPORT os
IMPORT xml
IMPORT FGL xcftypes

-- Module-level parsed state
DEFINE m_gas t_gas_config
DEFINE m_app t_app_config

-- ─── MAIN ────────────────────────────────────────────────────────────────────

MAIN
    DEFINE l_xcf_file   STRING
    DEFINE l_as_xcf     STRING
    DEFINE l_ua_groups  STRING
    DEFINE l_ws_groups  STRING
    DEFINE l_as_config  STRING
    DEFINE l_show_url   BOOLEAN
    DEFINE l_show_env   BOOLEAN
    DEFINE l_env        t_env_var_list
    DEFINE i            INTEGER

    LET l_show_url = TRUE
    LET l_show_env = TRUE

    # create same screen space
    DISPLAY "\n***xcfinfo"

    LET i = 1
    WHILE i <= num_args()
        CASE arg_val(i)
            WHEN "--url"
                LET l_show_url = TRUE
            WHEN "--no-url"
                LET l_show_url = FALSE
            WHEN "--env"
                LET l_show_env = TRUE
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
            OTHERWISE
                IF l_xcf_file IS NULL THEN
                    LET l_xcf_file = arg_val(i)
                END IF
        END CASE
        LET i = i + 1
    END WHILE

    IF l_xcf_file IS NULL THEN
        DISPLAY "Usage: fglrun xcfinfo <app.xcf> [--env|--no-env] [--url|--no-url] [--ua-groups <file>|--ws-groups <file>] [--as-config <file>]"
        EXIT PROGRAM 1
    END IF

    IF l_ua_groups IS NOT NULL AND l_ws_groups IS NOT NULL THEN
        DISPLAY "Error: --ua-groups and --ws-groups are mutually exclusive"
        EXIT PROGRAM 1
    END IF

    IF l_as_config IS NOT NULL THEN
        LET l_as_xcf = l_as_config
    ELSE
        LET l_as_xcf = fgl_getenv("FGLASDIR") || os.Path.separator() || "etc" || os.Path.separator() || "as.xcf"
    END IF
    DISPLAY SFMT("Configuration file to read: %1", l_as_xcf)

    -- Load GAS server settings (resources, exec env vars, groups, port) from as.xcf.
    CALL parse_as_xcf(l_as_xcf)
    -- Load the application identity, execution path, module, and env overrides from the app XCF.
    CALL parse_app_xcf(l_xcf_file)
    IF l_ua_groups IS NOT NULL THEN
        -- Use the caller-supplied APPLICATION_GROUPS file to resolve group → URL path mappings.
        CALL parse_group_file(l_ua_groups, "ua")
    ELSE
        IF l_ws_groups IS NOT NULL THEN
            -- Use the caller-supplied SERVICE_GROUPS file to resolve group → URL path mappings.
            CALL parse_group_file(l_ws_groups, "ws")
        ELSE
            -- No group file supplied: query the running fastcgidispatch process for its group files.
            CALL load_dispatcher_groups()
        END IF
    END IF
    -- Expand all $(resource) tokens across resources, env vars, and group paths.
    CALL resolve_resources()

    IF l_show_url THEN
        DISPLAY build_url(l_xcf_file)
    END IF

    IF l_show_env THEN
        -- Merge GAS exec-component env vars with app-level overrides (APPEND/PREPEND rules applied).
        CALL collect_env_vars() RETURNING l_env
        FOR i = 1 TO l_env.getLength()
            DISPLAY l_env[i].id || "=" || l_env[i].value
        END FOR
    END IF

END MAIN

-- ─── XML HELPERS ─────────────────────────────────────────────────────────────

-- Return the trimmed text content of an element node.
FUNCTION get_text(node xml.DomNode) RETURNS STRING
    DEFINE child xml.DomNode
    LET child = node.getFirstChild()
    WHILE child IS NOT NULL
        IF child.getNodeType() == "TEXT_NODE" THEN
            RETURN child.getNodeValue().trim()
        END IF
        LET child = child.getNextSibling()
    END WHILE
    RETURN ""
END FUNCTION

-- Return the first child element whose tag matches `tag`, or NULL.
FUNCTION find_child_elem(parent xml.DomNode, tag STRING) RETURNS xml.DomNode
    DEFINE child xml.DomNode
    LET child = parent.getFirstChildElement()
    WHILE child IS NOT NULL
        IF child.getNodeName() == tag THEN
            RETURN child
        END IF
        LET child = child.getNextSiblingElement()
    END WHILE
    RETURN NULL
END FUNCTION

-- ─── RESOURCE MANAGEMENT ─────────────────────────────────────────────────────

-- Add or update a resource in m_gas.resources (UNX entries override PI ones).
FUNCTION upsert_resource(id STRING, source STRING, value STRING)
    DEFINE i INTEGER
    FOR i = 1 TO m_gas.resources.getLength()
        IF m_gas.resources[i].id == id THEN
            LET m_gas.resources[i].source = source
            LET m_gas.resources[i].value  = value
            RETURN
        END IF
    END FOR
    LET i = m_gas.resources.getLength() + 1
    LET m_gas.resources[i].id     = id
    LET m_gas.resources[i].source = source
    LET m_gas.resources[i].value  = value
END FUNCTION

-- Parse all <RESOURCE> children of `container` into m_gas.resources.
FUNCTION parse_resource_nodes(container xml.DomNode)
    DEFINE child xml.DomNode
    LET child = container.getFirstChildElement()
    WHILE child IS NOT NULL
        IF child.getNodeName() == "RESOURCE" THEN
            CALL upsert_resource(
                child.getAttribute("Id"),
                child.getAttribute("Source"),
                get_text(child))
        END IF
        LET child = child.getNextSiblingElement()
    END WHILE
END FUNCTION

-- Parse all <ENVIRONMENT_VARIABLE> children of `container` into `list` and return it.
FUNCTION parse_env_nodes(container xml.DomNode, list t_env_var_list)
    RETURNS t_env_var_list
    DEFINE child xml.DomNode
    DEFINE idx   INTEGER
    LET child = container.getFirstChildElement()
    WHILE child IS NOT NULL
        IF child.getNodeName() == "ENVIRONMENT_VARIABLE" THEN
            LET idx              = list.getLength() + 1
            LET list[idx].id     = child.getAttribute("Id")
            LET list[idx].concat = child.getAttribute("Concat")
            LET list[idx].value  = get_text(child)
        END IF
        LET child = child.getNextSiblingElement()
    END WHILE
    RETURN list
END FUNCTION

-- ─── PARSERS ─────────────────────────────────────────────────────────────────

-- Parse $FGLASDIR/etc/as.xcf into m_gas.
FUNCTION parse_as_xcf(filename STRING)
    DEFINE doc   xml.DomDocument
    DEFINE root  xml.DomNode
    DEFINE as_nd xml.DomNode
    DEFINE rl_nd xml.DomNode
    DEFINE pi_nd xml.DomNode
    DEFINE cl_nd xml.DomNode
    DEFINE al_nd xml.DomNode
    DEFINE ic_nd xml.DomNode
    DEFINE child xml.DomNode
    DEFINE sub   xml.DomNode
    DEFINE idx   INTEGER

    LET doc = xml.DomDocument.Create()
    CALL doc.load(filename)
    LET root  = doc.getDocumentElement()         -- <CONFIGURATION>
    LET as_nd = find_child_elem(root, "APPLICATION_SERVER")
    IF as_nd IS NULL THEN RETURN END IF

    -- RESOURCE_LIST: PLATFORM_INDEPENDENT first, then UNX overrides
    LET rl_nd = find_child_elem(as_nd, "RESOURCE_LIST")
    IF rl_nd IS NOT NULL THEN
        LET pi_nd = find_child_elem(rl_nd, "PLATFORM_INDEPENDENT")
        IF pi_nd IS NOT NULL THEN CALL parse_resource_nodes(pi_nd) END IF
        LET pi_nd = find_child_elem(rl_nd, "UNX")
        IF pi_nd IS NOT NULL THEN CALL parse_resource_nodes(pi_nd) END IF
    END IF

    -- COMPONENT_LIST: collect env vars from cpn.wa.execution.local
    LET cl_nd = find_child_elem(as_nd, "COMPONENT_LIST")
    IF cl_nd IS NOT NULL THEN
        LET child = cl_nd.getFirstChildElement()
        WHILE child IS NOT NULL
            IF child.getAttribute("Id") == "cpn.wa.execution.local" THEN
                CALL parse_env_nodes(child, m_gas.exec_env)
                    RETURNING m_gas.exec_env
                EXIT WHILE
            END IF
            LET child = child.getNextSiblingElement()
        END WHILE
    END IF

    -- APPLICATION_LIST: collect GROUP → path mappings for URL resolution
    LET al_nd = find_child_elem(as_nd, "APPLICATION_LIST")
    IF al_nd IS NOT NULL THEN
        LET child = al_nd.getFirstChildElement()
        WHILE child IS NOT NULL
            IF child.getNodeName() == "GROUP" THEN
                LET idx                          = m_gas.groups.getLength() + 1
                LET m_gas.groups[idx].id         = child.getAttribute("Id")
                LET m_gas.groups[idx].path       = get_text(child)
                LET m_gas.groups[idx].group_type = "ua"
            END IF
            LET child = child.getNextSiblingElement()
        END WHILE
    END IF

    -- INTERFACE_TO_CONNECTOR: TCP_SERVER_PORT
    LET ic_nd = find_child_elem(as_nd, "INTERFACE_TO_CONNECTOR")
    IF ic_nd IS NOT NULL THEN
        LET sub = find_child_elem(ic_nd, "TCP_SERVER_PORT")
        IF sub IS NOT NULL THEN
            LET m_gas.server_port = get_text(sub)
        END IF
    END IF

END FUNCTION

-- Parse the application XCF file into m_app.
FUNCTION parse_app_xcf(filename STRING)
    DEFINE doc     xml.DomDocument
    DEFINE root    xml.DomNode
    DEFINE exec_nd xml.DomNode
    DEFINE sub     xml.DomNode

    TRY
        LET doc = xml.DomDocument.Create()
        CALL doc.load(filename)
        LET root = doc.getDocumentElement()          -- <APPLICATION>

        LET m_app.id     = xcf_app_name(filename)
        LET m_app.parent = root.getAttribute("Parent")

        LET exec_nd = find_child_elem(root, "EXECUTION")
        IF exec_nd IS NOT NULL THEN
            LET sub = find_child_elem(exec_nd, "PATH")
            IF sub IS NOT NULL THEN LET m_app.path = get_text(sub) END IF
            LET sub = find_child_elem(exec_nd, "MODULE")
            IF sub IS NOT NULL THEN LET m_app.module = get_text(sub) END IF
            CALL parse_env_nodes(exec_nd, m_app.env_vars) RETURNING m_app.env_vars
        END IF

        -- Expose application.path so $(application.path) can be expanded in env vars
        IF m_app.path IS NOT NULL THEN
            CALL upsert_resource("application.path", "INTERNAL", m_app.path)
        END IF
    CATCH
        DISPLAY SFMT("Unable to parse %1", filename)
        EXIT PROGRAM 2
    END TRY 

END FUNCTION

-- ─── RESOURCE RESOLUTION ─────────────────────────────────────────────────────

-- Return the resolved value for `id`: first from m_gas.resources, then from env.
FUNCTION find_resource_value(id STRING) RETURNS STRING
    DEFINE i INTEGER
    FOR i = 1 TO m_gas.resources.getLength()
        IF m_gas.resources[i].id == id THEN
            RETURN m_gas.resources[i].value
        END IF
    END FOR
    RETURN fgl_getenv(id)
END FUNCTION

-- Expand all $(name) tokens in `s` using m_gas.resources (max 50 substitutions).
-- In Genero BDL empty STRING == NULL; every concatenation branch explicitly
-- avoids combining NULL operands so NULL cannot propagate into the result.
FUNCTION expand_refs(s STRING) RETURNS STRING
    DEFINE result  STRING
    DEFINE search  STRING
    DEFINE ref_val STRING
    DEFINE suffix  STRING
    DEFINE ps, pe  INTEGER
    DEFINE it      INTEGER

    LET result = s
    LET it = 50
    WHILE it > 0
        IF result IS NULL THEN EXIT WHILE END IF
        -- Prepend sentinel: getIndexOf(pattern, n) begins AFTER position n,
        -- so start=1 would miss a token at position 1 without this sentinel.
        LET search = "_" || result
        LET ps     = search.getIndexOf("$(", 1) - 1
        IF ps <= 0 THEN EXIT WHILE END IF
        LET pe = result.getIndexOf(")", ps + 2)
        IF pe == 0 THEN EXIT WHILE END IF

        LET ref_val = find_resource_value(result.subString(ps + 2, pe - 1))

        IF pe < result.getLength() THEN
            LET suffix = result.subString(pe + 1, result.getLength())
        ELSE
            LET suffix = NULL
        END IF

        -- Assemble, never concatenating a NULL operand
        IF ps > 1 THEN
            IF ref_val IS NOT NULL THEN
                IF suffix IS NOT NULL THEN
                    LET result = result.subString(1, ps - 1) || ref_val || suffix
                ELSE
                    LET result = result.subString(1, ps - 1) || ref_val
                END IF
            ELSE
                IF suffix IS NOT NULL THEN
                    LET result = result.subString(1, ps - 1) || suffix
                ELSE
                    LET result = result.subString(1, ps - 1)
                END IF
            END IF
        ELSE
            IF ref_val IS NOT NULL THEN
                IF suffix IS NOT NULL THEN
                    LET result = ref_val || suffix
                ELSE
                    LET result = ref_val
                END IF
            ELSE
                LET result = suffix     -- may be NULL; loop guard handles it
            END IF
        END IF
        LET it = it - 1
    END WHILE
    RETURN result
END FUNCTION

-- Resolve all $(xxx) references across resources, env vars, and group paths.
FUNCTION resolve_resources()
    DEFINE i    INTEGER
    DEFINE pass INTEGER

    -- ENVIRON-sourced resources: value is the env var name to look up
    FOR i = 1 TO m_gas.resources.getLength()
        IF m_gas.resources[i].source == "ENVIRON" THEN
            LET m_gas.resources[i].value = fgl_getenv(m_gas.resources[i].value)
        END IF
    END FOR

    -- 10 passes handle chains where resource A references resource B
    FOR pass = 1 TO 10
        FOR i = 1 TO m_gas.resources.getLength()
            IF m_gas.resources[i].source != "ENVIRON" THEN
                LET m_gas.resources[i].value = expand_refs(m_gas.resources[i].value)
            END IF
        END FOR
    END FOR

    FOR i = 1 TO m_gas.exec_env.getLength()
        LET m_gas.exec_env[i].value = expand_refs(m_gas.exec_env[i].value)
    END FOR

    FOR i = 1 TO m_app.env_vars.getLength()
        LET m_app.env_vars[i].value = expand_refs(m_app.env_vars[i].value)
    END FOR

    FOR i = 1 TO m_gas.groups.getLength()
        LET m_gas.groups[i].path = expand_refs(m_gas.groups[i].path)
    END FOR

    LET m_gas.server_port = expand_refs(m_gas.server_port)

END FUNCTION

-- ─── ENV VAR COLLECTION ──────────────────────────────────────────────────────

-- Return the merged DVM environment: execution component vars + app overrides.
FUNCTION collect_env_vars() RETURNS t_env_var_list
    DEFINE result t_env_var_list
    DEFINE i, j   INTEGER
    DEFINE found  BOOLEAN

    FOR i = 1 TO m_gas.exec_env.getLength()
        LET result[result.getLength() + 1].* = m_gas.exec_env[i].*
    END FOR

    FOR i = 1 TO m_app.env_vars.getLength()
        LET found = FALSE
        FOR j = 1 TO result.getLength()
            IF result[j].id == m_app.env_vars[i].id THEN
                CASE m_app.env_vars[i].concat
                    WHEN "APPEND"
                        LET result[j].value = result[j].value
                                           || ":"
                                           || m_app.env_vars[i].value
                    WHEN "PREPEND"
                        LET result[j].value = m_app.env_vars[i].value
                                           || ":"
                                           || result[j].value
                    OTHERWISE
                        LET result[j].value = m_app.env_vars[i].value
                END CASE
                LET found = TRUE
                EXIT FOR
            END IF
        END FOR
        IF NOT found THEN
            LET result[result.getLength() + 1].* = m_app.env_vars[i].*
        END IF
    END FOR

    RETURN result
END FUNCTION

-- ─── URL CONSTRUCTION ────────────────────────────────────────────────────────

-- Parse an APPLICATION_GROUPS or SERVICE_GROUPS XML file and append to m_gas.groups.
-- Pass NULL for group_type to auto-detect from the root element name.
FUNCTION parse_group_file(filename STRING, group_type STRING)
    DEFINE doc      xml.DomDocument
    DEFINE root     xml.DomNode
    DEFINE child    xml.DomNode
    DEFINE eff_type STRING
    DEFINE idx      INTEGER

    IF NOT os.Path.exists(filename) THEN RETURN END IF
    LET doc = xml.DomDocument.Create()
    CALL doc.load(filename)
    LET root = doc.getDocumentElement()
    IF root IS NULL THEN RETURN END IF

    IF group_type == "ua" THEN
        IF root.getNodeName() != "APPLICATION_GROUPS" THEN RETURN END IF
        LET eff_type = "ua"
    ELSE
        IF group_type == "ws" THEN
            IF root.getNodeName() != "SERVICE_GROUPS" THEN RETURN END IF
            LET eff_type = "ws"
        ELSE
            -- auto-detect from root element (called by load_dispatcher_groups)
            IF root.getNodeName() == "APPLICATION_GROUPS" THEN
                LET eff_type = "ua"
            ELSE
                LET eff_type = "ws"
            END IF
        END IF
    END IF

    LET child = root.getFirstChildElement()
    WHILE child IS NOT NULL
        IF child.getNodeName() == "GROUP" THEN
            LET idx                          = m_gas.groups.getLength() + 1
            LET m_gas.groups[idx].id         = child.getAttribute("Id")
            LET m_gas.groups[idx].path       = get_text(child)
            LET m_gas.groups[idx].group_type = eff_type
        END IF
        LET child = child.getNextSiblingElement()
    END WHILE
END FUNCTION

-- Return the value of a named command-line flag from a line of text.
-- Uses the sentinel trick (prepend "_") so flags at position 1 are not missed.
FUNCTION extract_flag_value(line STRING, flag STRING) RETURNS STRING
    DEFINE sentinel  STRING
    DEFINE pos       INTEGER
    DEFINE val_start INTEGER
    DEFINE rest      STRING
    DEFINE sp        INTEGER

    LET sentinel = "_" || line
    LET pos = sentinel.getIndexOf(flag, 1) - 1
    IF pos <= 0 THEN RETURN NULL END IF

    LET val_start = pos + flag.getLength() + 1  -- skip flag + trailing space
    IF val_start > line.getLength() THEN RETURN NULL END IF
    LET rest = line.subString(val_start, line.getLength())

    LET sentinel = "_" || rest
    LET sp = sentinel.getIndexOf(" ", 1) - 1   -- first space in rest
    IF sp > 0 THEN
        RETURN rest.subString(1, sp - 1)
    ELSE
        RETURN rest
    END IF
END FUNCTION

-- Query the running fastcgidispatch process for its --application-group and
-- --service-group arguments, then load the referenced group XML files.
FUNCTION load_dispatcher_groups()
    DEFINE ch      base.Channel
    DEFINE line    STRING
    DEFINE app_grp STRING
    DEFINE svc_grp STRING
    DEFINE cmd     STRING

    IF os.Path.separator() == "/" THEN
        LET cmd = "ps -fea 2>/dev/null | grep '[f]astcgidispatch'"
    ELSE
        LET cmd = "wmic process where \"name like '%fastcgidispatch%'\" get commandline /format:list 2>nul"
    END IF

    LET ch = base.Channel.create()
    CALL ch.openPipe(cmd, "r")
    WHILE ch.read([line])
        IF app_grp IS NULL THEN
            LET app_grp = extract_flag_value(line, "--application-group")
        END IF
        IF svc_grp IS NULL THEN
            LET svc_grp = extract_flag_value(line, "--service-group")
        END IF
    END WHILE
    CALL ch.close()

    IF app_grp IS NOT NULL THEN
        CALL parse_group_file(app_grp, "ua")
    END IF
    IF svc_grp IS NOT NULL THEN
        CALL parse_group_file(svc_grp, "ws")
    END IF
END FUNCTION

-- Return the XCF filename without its extension (the GAS application name).
FUNCTION xcf_app_name(path STRING) RETURNS STRING
    DEFINE base STRING
    DEFINE ext  STRING
    LET base = os.Path.BaseName(path)
    LET ext  = os.Path.Extension(base)
    IF ext.getLength() > 0 THEN
        RETURN base.subString(1, base.getLength() - ext.getLength() - 1)
    END IF
    RETURN base
END FUNCTION

-- Build the GAS browser URL for the application.
-- URL = http://localhost:<res.ic.server.port>/<ua|ws>/r/<group>/<appname>
-- Group and url-type come from the group XML files; port from as.xcf.
FUNCTION build_url(xcf_file STRING) RETURNS STRING
    DEFINE port      STRING
    DEFINE url_type  STRING
    DEFINE group_id  STRING
    DEFINE xcf_dir   STRING
    DEFINE i         INTEGER

    LET port = m_gas.server_port
    IF port IS NULL THEN LET port = "6394" END IF

    LET xcf_dir  = os.Path.DirName(xcf_file)
    # if no path was given then the file is in the current folder
    IF xcf_dir.trim().getLength() == 0 THEN
        LET xcf_dir = os.Path.pwd()
    END IF 
    LET url_type = "ua"
    LET group_id = "_default"
    FOR i = 1 TO m_gas.groups.getLength()
        IF xcf_dir == m_gas.groups[i].path THEN
            LET url_type = m_gas.groups[i].group_type
            LET group_id = m_gas.groups[i].id
            EXIT FOR
        END IF
    END FOR

    RETURN "http://localhost:" || port || "/" || url_type || "/r/" || group_id || "/" || xcf_app_name(xcf_file)
END FUNCTION
