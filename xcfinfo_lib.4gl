-- xcfinfo_lib — GAS configuration inspector library
--
-- Library module for xcfinfo. Contains all parsing, resolution, URL-building,
-- and environment variable collection logic. The run() function implements
-- the full program logic and is called from xcfinfo.FUNCTION main().
--

#+ xcfinfo_lib — GAS configuration inspector library.
#+
#+ Provides all parsing, resolution, and URL-building functions used by xcfinfo.
#+ Import this module to access its PUBLIC functions from other programs.


IMPORT os
IMPORT xml
IMPORT util
IMPORT FGL xcfinfo_types

-- Module-level parsed state
#+ Parsed GAS server configuration: resources, exec env vars, group mappings, and TCP port.
DEFINE m_gas     t_gas_config
#+ Parsed application XCF configuration: identity, execution path, module, and env var overrides.
DEFINE m_app     t_app_config
#+ When TRUE, emit diagnostic messages about each processing step to standard output.
DEFINE m_verbose BOOLEAN

-- ─── RUN ─────────────────────────────────────────────────────────────────────

#+ Execute the full xcfinfo inspection: load configuration, resolve resources,
#+ and display the browser URL and DVM environment variable set.
#+ All parameters are NULL-safe; defaults are applied for any NULL value.
#+
#+ @param xcf_file       Path to the application XCF file.
#+ @param as_config      Path to as.xcf override; NULL uses $FGLASDIR/etc/as.xcf.
#+ @param ua_groups      APPLICATION_GROUPS file override; NULL uses the running dispatcher.
#+ @param ws_groups      SERVICE_GROUPS file override; NULL uses the running dispatcher.
#+ @param protocol       URL protocol ("http"/"https"); NULL defaults to "http".
#+ @param host           URL hostname; NULL defaults to "localhost".
#+ @param port_override  URL port override; NULL reads the port from as.xcf.
#+ @param show_env       TRUE to display env vars; NULL defaults to TRUE.
#+ @param verbose        TRUE to emit diagnostic output; NULL defaults to FALSE.
PUBLIC FUNCTION inspect_app(
        xcf_file      STRING,
        as_config     STRING,
        ua_groups     STRING,
        ws_groups     STRING,
        protocol      STRING,
        host          STRING,
        port_override STRING,
        show_env      BOOLEAN,
        verbose       BOOLEAN)
    DEFINE l_as_xcf STRING          # resolved path to as.xcf
    DEFINE l_env    t_env_var_list  # merged DVM environment variables
    DEFINE i        INTEGER         # loop counter

    -- Apply defaults for unspecified options
    IF protocol IS NULL THEN LET protocol = "https"     END IF
    IF host     IS NULL THEN LET host     = "localhost" END IF
    IF show_env IS NULL THEN LET show_env = TRUE        END IF
    IF verbose  IS NULL THEN LET verbose  = FALSE       END IF
    LET m_verbose = verbose

    # create same screen space
    DISPLAY "\n***xcfinfo"

    IF as_config IS NOT NULL THEN
        LET l_as_xcf = as_config
    ELSE
        LET l_as_xcf = fgl_getenv("FGLASDIR") || os.Path.separator() || "etc" || os.Path.separator() || "as.xcf"
    END IF
    DISPLAY SFMT("Configuration file to read: %1", l_as_xcf)

    -- Load GAS server settings (resources, exec env vars, groups, port) from as.xcf.
    CALL parse_as_xcf(l_as_xcf)
    IF m_verbose THEN
        DISPLAY SFMT("[verbose] GAS resources loaded: %1", m_gas.resources.getLength())
        DISPLAY SFMT("[verbose] GAS server port (raw): %1", m_gas.server_port)
        DISPLAY SFMT("[verbose] GAS groups from as.xcf: %1", m_gas.groups.getLength())
    END IF

    -- Load the application identity, execution path, module, and env overrides from the app XCF.
    CALL parse_app_xcf(xcf_file)
    IF m_verbose THEN
        DISPLAY SFMT("[verbose] App id: %1", m_app.id)
        DISPLAY SFMT("[verbose] App parent: %1", m_app.parent)
        DISPLAY SFMT("[verbose] App path (raw): %1", m_app.path)
        DISPLAY SFMT("[verbose] App module: %1", m_app.module)
        DISPLAY SFMT("[verbose] App env vars: %1", m_app.env_vars.getLength())
    END IF

    -- Always query the running fastcgidispatch process for its group files first.
    CALL load_dispatcher_groups()
    -- A caller-supplied file overrides the dispatcher result for its type.
    IF ua_groups IS NOT NULL THEN
        CALL parse_group_file(ua_groups, "ua")
    ELSE
        IF ws_groups IS NOT NULL THEN
            CALL parse_group_file(ws_groups, "ws")
        END IF
    END IF
    IF m_verbose THEN
        DISPLAY SFMT("[verbose] Total groups after all sources: %1", m_gas.groups.getLength())
    END IF

    -- Expand all $(resource) tokens across resources, env vars, and group paths.
    CALL resolve_resources()
    IF m_verbose THEN
        DISPLAY SFMT("[verbose] App path (resolved): %1", m_app.path)
        DISPLAY SFMT("[verbose] GAS server port (resolved): %1", m_gas.server_port)
    END IF

    DISPLAY build_url(xcf_file, protocol, host, port_override)

    IF show_env THEN
        -- Merge GAS exec-component env vars with app-level overrides (APPEND/PREPEND rules applied).
        CALL collect_env_vars() RETURNING l_env
        FOR i = 1 TO l_env.getLength()
            DISPLAY l_env[i].id || "=" || l_env[i].value
        END FOR
    END IF

END FUNCTION

-- ─── XML HELPERS ─────────────────────────────────────────────────────────────

#+ Return the trimmed text content of a DOM element node.
#+
#+ @param node  The DOM element node whose text content is wanted.
#+ @return      The trimmed text, or an empty string if no TEXT_NODE child exists.
PUBLIC FUNCTION get_text(node xml.DomNode) RETURNS STRING
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

#+ Return the first child element node whose tag name matches tag, or NULL.
#+
#+ @param parent  The parent DOM node to search.
#+ @param tag     The element tag name to match.
#+ @return        The first matching child element, or NULL if none found.
PUBLIC FUNCTION find_child_elem(parent xml.DomNode, tag STRING) RETURNS xml.DomNode
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

#+ Add or update a resource entry in m_gas.resources.
#+ If an entry with the same id already exists it is updated in place; UNX-sourced
#+ entries therefore override PLATFORM_INDEPENDENT entries when loaded second.
#+
#+ @param id      The resource identifier (e.g. "res.ic.server.port").
#+ @param source  The source attribute value (INTERNAL, ENVIRON, UNX, etc.).
#+ @param value   The resource value string, possibly containing $(token) references.
PUBLIC FUNCTION upsert_resource(id STRING, source STRING, value STRING)
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

#+ Parse all RESOURCE child elements of container and load them into m_gas.resources.
#+
#+ @param container  The parent DOM node (PLATFORM_INDEPENDENT or UNX section).
PUBLIC FUNCTION parse_resource_nodes(container xml.DomNode)
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

#+ Parse all ENVIRONMENT_VARIABLE child elements of container and append them to list.
#+
#+ @param container  The parent DOM node containing ENVIRONMENT_VARIABLE elements.
#+ @param list       The t_env_var_list to append the parsed entries to.
#+ @return           The updated list with all newly parsed entries appended.
PUBLIC FUNCTION parse_env_nodes(container xml.DomNode, list t_env_var_list)
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

#+ Parse the GAS server configuration file (as.xcf) into m_gas.
#+ Loads resources (PLATFORM_INDEPENDENT then UNX), execution component env vars,
#+ APPLICATION_LIST and SERVICE_LIST group-to-path mappings, and the TCP server port.
#+
#+ @param filename  Path to the as.xcf configuration file.
PUBLIC FUNCTION parse_as_xcf(filename STRING)
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

    -- APPLICATION_LIST then SERVICE_LIST: collect GROUP → path mappings for URL resolution
    VAR pass INTEGER
    FOR pass = 1 TO 2
        IF pass == 1 THEN
            LET al_nd = find_child_elem(as_nd, "APPLICATION_LIST")
        ELSE
            LET al_nd = find_child_elem(as_nd, "SERVICE_LIST")
        END IF
        IF al_nd IS NOT NULL THEN
            LET child = al_nd.getFirstChildElement()
            WHILE child IS NOT NULL
                IF child.getNodeName() == "GROUP" THEN
                    LET idx                          = m_gas.groups.getLength() + 1
                    LET m_gas.groups[idx].id         = child.getAttribute("Id")
                    LET m_gas.groups[idx].path       = get_text(child)
                    IF pass == 1 THEN
                        LET m_gas.groups[idx].group_type = "ua"
                    ELSE
                        LET m_gas.groups[idx].group_type = "ws"
                    END IF
                END IF
                LET child = child.getNextSiblingElement()
            END WHILE
        END IF
    END FOR

    -- INTERFACE_TO_CONNECTOR: TCP_SERVER_PORT
    LET ic_nd = find_child_elem(as_nd, "INTERFACE_TO_CONNECTOR")
    IF ic_nd IS NOT NULL THEN
        LET sub = find_child_elem(ic_nd, "TCP_SERVER_PORT")
        IF sub IS NOT NULL THEN
            LET m_gas.server_port = get_text(sub)
        END IF
    END IF

END FUNCTION

#+ Parse the Genero application XCF file into m_app.
#+ Reads the application id, parent, execution path, module, and env var overrides.
#+ Also registers application.path as a resource so $(application.path) can be expanded.
#+
#+ @param filename  Path to the application XCF file.
PUBLIC FUNCTION parse_app_xcf(filename STRING)
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

#+ Return the resolved value for a resource id.
#+ Searches m_gas.resources first; falls back to fgl_getenv() if not found.
#+
#+ @param id    The resource identifier to look up.
#+ @return      The resource value string, or the environment variable value if absent.
PUBLIC FUNCTION find_resource_value(id STRING) RETURNS STRING
    DEFINE i INTEGER
    FOR i = 1 TO m_gas.resources.getLength()
        IF m_gas.resources[i].id == id THEN
            RETURN m_gas.resources[i].value
        END IF
    END FOR
    RETURN fgl_getenv(id)
END FUNCTION

#+ Expand all $(name) resource-reference tokens in s (maximum 50 substitutions per call).
#+ Each $(name) token is replaced by the value returned by find_resource_value().
#+ Iterates to handle chained references; the 50-iteration limit prevents infinite
#+ loops on circular resource definitions.
#+
#+ @param s     The string that may contain $(resource.name) tokens.
#+ @return      The string with all resolvable tokens substituted by their values.
PUBLIC FUNCTION expand_refs(s STRING) RETURNS STRING
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

#+ Resolve all $(resource) tokens across all parsed configuration data.
#+ Applies 10-pass chain resolution to m_gas.resources, then expands tokens in
#+ m_gas.exec_env, m_app.env_vars, m_gas.groups paths, m_app.path, and m_gas.server_port.
PUBLIC FUNCTION resolve_resources()
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

    LET m_app.path        = expand_refs(m_app.path)
    LET m_gas.server_port = expand_refs(m_gas.server_port)

END FUNCTION

-- ─── ENV VAR COLLECTION ──────────────────────────────────────────────────────

#+ Return the merged DVM environment variable list ready for display.
#+ Starts from the GAS execution component variables, then applies app-level overrides
#+ using APPEND, PREPEND, or replace semantics according to each entry's Concat attribute.
#+
#+ @return  The merged t_env_var_list with all app-level overrides applied.
PUBLIC FUNCTION collect_env_vars() RETURNS t_env_var_list
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

#+ Parse an APPLICATION_GROUPS or SERVICE_GROUPS XML file and append entries to m_gas.groups.
#+ Pass NULL for group_type to auto-detect the type from the root element name.
#+
#+ @param filename    Path to the groups XML file.
#+ @param group_type  "ua" for APPLICATION_GROUPS, "ws" for SERVICE_GROUPS, NULL to auto-detect.
PUBLIC FUNCTION parse_group_file(filename STRING, group_type STRING)
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

    IF m_verbose THEN
        DISPLAY SFMT("[verbose] Loading group file: %1 (type: %2)", filename, eff_type)
    END IF
    LET child = root.getFirstChildElement()
    WHILE child IS NOT NULL
        IF child.getNodeName() == "GROUP" THEN
            LET idx                          = m_gas.groups.getLength() + 1
            LET m_gas.groups[idx].id         = child.getAttribute("Id")
            LET m_gas.groups[idx].path       = get_text(child)
            LET m_gas.groups[idx].group_type = eff_type
            IF m_verbose THEN
                DISPLAY SFMT("[verbose]   group id=%1  path=%2", m_gas.groups[idx].id, m_gas.groups[idx].path)
            END IF
        END IF
        LET child = child.getNextSiblingElement()
    END WHILE
END FUNCTION

#+ Return the value of a named command-line flag from a process command-line string.
#+ Uses a sentinel prefix so that flags appearing at position 1 of the string are found.
#+
#+ @param line  The full command-line string to search.
#+ @param flag  The flag name to locate (e.g. "--application-group").
#+ @return      The token immediately following the flag, or NULL if the flag is absent.
PUBLIC FUNCTION extract_flag_value(line STRING, flag STRING) RETURNS STRING
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

#+ Query the running fastcgidispatch process for its group file arguments.
#+ Reads --application-group and --service-group from the process command line
#+ via ps (Unix) or wmic (Windows), then loads the found files via parse_group_file().
PUBLIC FUNCTION load_dispatcher_groups()
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

    IF m_verbose THEN
        DISPLAY SFMT("[verbose] Dispatcher application-group file: %1", app_grp)
        DISPLAY SFMT("[verbose] Dispatcher service-group file: %1", svc_grp)
    END IF
    IF app_grp IS NOT NULL THEN
        CALL parse_group_file(app_grp, "ua")
    END IF
    IF svc_grp IS NOT NULL THEN
        CALL parse_group_file(svc_grp, "ws")
    END IF
END FUNCTION

#+ Return the GAS application name derived from an XCF file path.
#+ Strips the directory component and the .xcf extension from the path.
#+
#+ @param path  Full or relative path to the XCF file.
#+ @return      The base filename without the .xcf extension.
PUBLIC FUNCTION xcf_app_name(path STRING) RETURNS STRING
    DEFINE base STRING
    DEFINE ext  STRING
    LET base = os.Path.BaseName(path)
    LET ext  = os.Path.Extension(base)
    IF ext.getLength() > 0 THEN
        RETURN base.subString(1, base.getLength() - ext.getLength() - 1)
    END IF
    RETURN base
END FUNCTION

#+ Build the GAS browser URL for the application.
#+ URL format: protocol://host:port/genero/ua|ws/r/group/appname.
#+ "genero" is the Apache ProxyPass alias that forwards browser requests to the
#+ FastCGI dispatcher; it is not configurable from within GAS itself.
#+ The group is resolved by matching m_app.path against m_gas.groups, walking up
#+ the directory tree until a match is found or the path is exhausted.
#+
#+ @param xcf_file       Path to the application XCF file (provides the app name).
#+ @param protocol       URL protocol: "http" or "https".
#+ @param host           Server hostname or IP address for the URL.
#+ @param port_override  Port to use; NULL to read the port from as.xcf.
#+ @return               The fully composed GAS browser URL string.
PUBLIC FUNCTION build_url(xcf_file STRING, protocol STRING, host STRING, port_override STRING) RETURNS STRING
    DEFINE port      STRING
    DEFINE url_type  STRING
    DEFINE group_id  STRING
    DEFINE app_dir   STRING
    DEFINE i         INTEGER

    IF port_override IS NOT NULL THEN
        LET port = port_override
    ELSE
        LET port = m_gas.server_port
        IF port IS NULL THEN LET port = "6394" END IF
    END IF

    -- Use the PATH from the app XCF execution section; fall back to cwd if absent.
    LET app_dir = m_app.path
    IF app_dir IS NULL OR app_dir.trim().getLength() == 0 THEN
        LET app_dir = os.Path.pwd()
    END IF
    IF m_verbose THEN
        DISPLAY SFMT("[verbose] App execution path for group matching: %1", app_dir)
    END IF
    LET url_type = "ua"
    LET group_id = "_default"
    VAR search_dir STRING = app_dir
    WHILE search_dir IS NOT NULL AND search_dir.getLength() > 1
        IF m_verbose THEN
            DISPLAY SFMT("[verbose] Searching groups for path: %1", search_dir)
        END IF
        FOR i = 1 TO m_gas.groups.getLength()
            IF search_dir == m_gas.groups[i].path THEN
                LET url_type = m_gas.groups[i].group_type
                LET group_id = m_gas.groups[i].id
                EXIT FOR
            END IF
        END FOR
        IF group_id != "_default" THEN
            EXIT WHILE
        END IF
        LET search_dir = os.Path.DirName(search_dir)
    END WHILE
    IF m_verbose THEN
        DISPLAY SFMT("[verbose] Group matched: id=%1  type=%2", group_id, url_type)
        DISPLAY SFMT("[verbose] Port: %1", port)
    END IF

    RETURN SFMT("%1://%2:%3/genero/%4/r/%5/%6", protocol, host, port, url_type, group_id, xcf_app_name(xcf_file))
END FUNCTION
