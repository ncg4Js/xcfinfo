-- Types for xcfinfo: GAS XCF configuration parser

PUBLIC TYPE t_resource RECORD
    id     STRING,
    source STRING,
    value  STRING
END RECORD

PUBLIC TYPE t_resource_list DYNAMIC ARRAY OF t_resource

PUBLIC TYPE t_env_var RECORD
    id     STRING,
    value  STRING,
    concat STRING
END RECORD

PUBLIC TYPE t_env_var_list DYNAMIC ARRAY OF t_env_var

PUBLIC TYPE t_group RECORD
    id         STRING,
    path       STRING,
    group_type STRING
END RECORD

PUBLIC TYPE t_group_list DYNAMIC ARRAY OF t_group

PUBLIC TYPE t_gas_config RECORD
    resources   t_resource_list,
    exec_env    t_env_var_list,
    groups      t_group_list,
    server_port STRING
END RECORD

PUBLIC TYPE t_app_config RECORD
    id       STRING,
    parent   STRING,
    path     STRING,
    module   STRING,
    env_vars t_env_var_list
END RECORD
