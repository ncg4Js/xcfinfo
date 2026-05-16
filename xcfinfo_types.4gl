-- Types for xcfinfo: GAS XCF configuration parser

#+ Type definitions shared by xcfinfo modules.
#+
#+ Defines the record structures and array types used to hold parsed GAS server
#+ configuration (as.xcf) and Genero application XCF data.

#+ A single resource entry from the GAS RESOURCE_LIST.
#+   id     — resource identifier (e.g. "res.ic.server.port")
#+   source — origin type: INTERNAL, ENVIRON, UNX, or PLATFORM_INDEPENDENT
#+   value  — resource value; may contain $(token) references resolved by expand_refs()
PUBLIC TYPE t_resource RECORD
    id     STRING,
    source STRING,
    value  STRING
END RECORD

#+ Dynamic array of t_resource; holds all resources parsed from the RESOURCE_LIST in as.xcf.
PUBLIC TYPE t_resource_list DYNAMIC ARRAY OF t_resource

#+ A single environment variable entry from an EXECUTION component.
#+   id     — environment variable name
#+   value  — variable value; may contain $(token) references
#+   concat — merge rule when app overrides GAS value: APPEND, PREPEND, or empty (replace)
PUBLIC TYPE t_env_var RECORD
    id     STRING,
    value  STRING,
    concat STRING
END RECORD

#+ Dynamic array of t_env_var; used for both GAS execution component and app-level env var lists.
PUBLIC TYPE t_env_var_list DYNAMIC ARRAY OF t_env_var

#+ A group mapping entry from APPLICATION_LIST, SERVICE_LIST, or a group XML file.
#+   id         — group identifier used in the browser URL path (e.g. "dev")
#+   path       — filesystem directory the group maps to
#+   group_type — routing type: "ua" for interactive applications, "ws" for web services
PUBLIC TYPE t_group RECORD
    id         STRING,
    path       STRING,
    group_type STRING
END RECORD

#+ Dynamic array of t_group; accumulates all group mappings from all sources.
PUBLIC TYPE t_group_list DYNAMIC ARRAY OF t_group

#+ Complete parsed state of the GAS server configuration (as.xcf).
#+   resources   — all resources parsed from the RESOURCE_LIST
#+   exec_env    — env vars from the cpn.wa.execution.local execution component
#+   groups      — group-to-path mappings from APPLICATION_LIST, SERVICE_LIST, and group XML files
#+   server_port — TCP port the GAS dispatcher listens on (from TCP_SERVER_PORT)
PUBLIC TYPE t_gas_config RECORD
    resources   t_resource_list,
    exec_env    t_env_var_list,
    groups      t_group_list,
    server_port STRING
END RECORD

#+ Complete parsed state of a Genero application XCF file.
#+   id       — application name derived from the XCF filename (without .xcf extension)
#+   parent   — parent application identifier from the Parent XML attribute
#+   path     — execution path from the PATH node in the EXECUTION section
#+   module   — module name from the MODULE node in the EXECUTION section
#+   env_vars — application-level env var overrides from the EXECUTION section
PUBLIC TYPE t_app_config RECORD
    id       STRING,
    parent   STRING,
    path     STRING,
    module   STRING,
    env_vars t_env_var_list
END RECORD
