import os
import argparse
import json
import csv
import time
from datetime import datetime, timedelta
import re
import subprocess
import mysql.connector
from mysql.connector import Error

class DateTimeEncoder(json.JSONEncoder):
    """Custom JSON encoder for datetime objects"""
    def default(self, obj):
        if isinstance(obj, datetime):
            return obj.strftime('%Y-%m-%d %H:%M:%S')
        return super().default(obj)

class StarRocksDoctor:
    def __init__(self, host, port, user, password, output_dir='./starrocks_diagnostic'):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.output_dir = output_dir
        self.connection = None
        self.timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    def connect(self):
        """Establish connection to the StarRocks cluster"""
        try:
            self.connection = mysql.connector.connect(
                host=self.host,
                port=self.port,
                user=self.user,
                password=self.password
            )
            return True
        except Error as e:
            print(f"Error connecting to StarRocks: {e}")
            return False

    def execute_query(self, query, params=None):
        """Execute a query and return results"""
        cursor = self.connection.cursor(dictionary=True)
        try:
            cursor.execute(query, params or ())
            return cursor.fetchall()
        except Error as e:
            print(f"Error executing query: {query}\nError: {e}")
            return None
        finally:
            cursor.close()
    
    def get_leader_fe(self):
        """Get the leader FE"""
        fe_instances = self.execute_query("show frontends")
        for fe in fe_instances:
            if fe['Role'] == 'LEADER':
                return fe['IP']
        return None
    
    def get_fes(self):
        """Get all FE"""
        fes = []
        fe_instances = self.execute_query("show frontends")
        for fe in fe_instances:
            fes.append(fe['IP'])
        return fes


    def collect_cluster_state(self):
        """Collect cluster state and configuration"""
        return {
            'backends': self.execute_query("SHOW PROC '/backends'"),
            'frontends': self.execute_query("SHOW PROC '/frontends'"),
            'resource_groups': self.execute_query("SHOW RESOURCE GROUPS"),
            'version': self.execute_query("SELECT current_version()")[0]['current_version()']
        }

    def collect_performance_diagnostics(self, limit=100):
        """Collect query performance diagnostics from all FE nodes"""
        try:
            # Get all FE nodes
            fe_nodes = self.execute_query("SHOW PROC '/frontends'")
            if not fe_nodes:
                print("Error: Could not get FE nodes information")
                return {}

            all_queries = []
            all_current_queries = []
            original_host = self.host

            # Collect queries from each FE node
            for fe in fe_nodes:
                fe_host = fe['IP']
                try:
                    # Switch connection to this FE
                    if self.connection:
                        self.connection.close()
                    self.host = fe_host
                    if not self.connect():
                        print(f"Warning: Could not connect to FE {fe_host}")
                        continue

                    # Get queries from this FE
                    try:
                        queries = self.execute_query("""
                            SELECT 
                                queryId,
                                timestamp,
                                user,
                                state,
                                queryTime,
                                scanBytes,
                                scanRows,
                                returnRows,
                                cpuCostNs,
                                memCostBytes,
                                %s as fe_host
                            FROM starrocks_audit_db__.starrocks_audit_tbl__
                            ORDER BY timestamp DESC
                            LIMIT %s
                        """, (fe_host, limit))
                        
                        if queries:
                            all_queries.extend(queries)
                    except Exception:
                        # Silently skip if query history is not available
                        pass

                    # Get current queries from this FE
                    try:
                        current_queries = self.execute_query("SHOW PROC '/current_queries'")
                        if current_queries:
                            for query in current_queries:
                                query['fe_host'] = fe_host
                            all_current_queries.extend(current_queries)
                    except Exception:
                        # Silently skip if current_queries is not available
                        pass

                except Exception as e:
                    print(f"Error collecting queries from FE {fe_host}: {e}")
                finally:
                    # Close connection to this FE
                    if self.connection:
                        self.connection.close()

            # Sort all queries by timestamp and take the most recent ones
            all_queries.sort(key=lambda x: x['timestamp'], reverse=True)
            recent_queries = all_queries[:limit]

            # Restore original connection
            self.host = original_host
            if not self.connect():
                print("Error: Could not restore connection to original FE")
                return {}

            return {
                'recent_queries': recent_queries,
                'current_queries': all_current_queries,
                'active_queries': self.execute_query("SHOW PROCESSLIST")
            }
        except Exception as e:
            print(f"Error collecting performance diagnostics: {e}")
            return {}

    def save_to_file(self, data, filename, format='json'):
        """Save collected data to file
        Args:
            data: Data to save
            filename: Base filename without extension
            format: Output format ('json', 'csv', 'yaml', 'txt')
        Returns:
            str: Path to the saved file
        """
        os.makedirs(self.output_dir, exist_ok=True)
        filepath = os.path.join(self.output_dir, f"{filename}_{self.timestamp}.{format}")

        with open(filepath, 'w') as f:
            if format == 'json':
                json.dump(data, f, indent=2, cls=DateTimeEncoder)
            elif format == 'csv':
                if isinstance(data, dict):
                    # For dictionary data, create a flattened CSV
                    writer = csv.writer(f)
                    writer.writerow(['Key', 'Value'])
                    for key, value in data.items():
                        if isinstance(value, dict):
                            for subkey, subvalue in value.items():
                                writer.writerow([f"{key}.{subkey}", subvalue])
                        else:
                            writer.writerow([key, value])
                else:
                    # For list data, write as is
                    writer = csv.writer(f)
                    if data and len(data) > 0:
                        writer.writerow(data[0].keys())
                        for row in data:
                            writer.writerow(row.values())
            elif format == 'yaml':
                import yaml
                yaml.dump(data, f, default_flow_style=False, allow_unicode=True)
            elif format == 'txt':
                if isinstance(data, dict):
                    for key, value in data.items():
                        f.write(f"{key}: {value}\n")
                else:
                    for item in data:
                        f.write(f"{item}\n")
            else:
                raise ValueError(f"Unsupported format: {format}")

        return filepath

    def run_diagnostics(self):
        """Main method to run all diagnostics"""
        if not self.connect():
            return False

        try:
            print("Collecting schema information...")
            schema_info = self.collect_schema_info()
            self.save_to_file(schema_info, 'schema_info')

            print("Collecting cluster state...")
            cluster_state = self.collect_cluster_state()
            self.save_to_file(cluster_state, 'cluster_state')

            print("Collecting performance diagnostics...")
            perf_diag = self.collect_performance_diagnostics()
            self.save_to_file(perf_diag, 'performance_diagnostics')

            print(f"Diagnostic data collection complete. Files saved to {self.output_dir}")
            return True
        finally:
            if self.connection:
                self.connection.close()

    def _convert_to_mb(self, size_str):
        """Convert size string to MB
        Args:
            size_str: Size string with unit (e.g. '14.2GB', '12KB', '977B')
        Returns:
            float: Size in MB
        """
        try:
            # Remove any whitespace
            size_str = size_str.strip()
            
            # Get the numeric part and unit
            numeric_part = ''.join(c for c in size_str if c.isdigit() or c == '.')
            unit = ''.join(c for c in size_str if c.isalpha()).upper()
            
            # Convert to float
            size = float(numeric_part)
            
            # Convert to MB based on unit
            if unit == 'B':
                return size / (1024 * 1024)
            elif unit == 'KB':
                return size / 1024
            elif unit == 'MB':
                return size
            elif unit == 'GB':
                return size * 1024
            elif unit == 'TB':
                return size * 1024 * 1024
            else:
                print(f"Warning: Unknown unit {unit} in size string {size_str}")
                return 0.0
        except Exception as e:
            print(f"Warning: Error converting size {size_str} to MB: {e}")
            return 0.0

    def collect_table_info(self, table_name=None):
        """Collect table schema and detailed information
        Args:
            table_name: Optional. If specified, only collect info for this table
        Returns:
            dict: Dictionary containing table information
        """
        try:
            schema_info = {}
            query = """
                SELECT t.TABLE_SCHEMA, t.TABLE_NAME, t.TABLE_TYPE, c.TABLE_ID
                FROM information_schema.tables t
                LEFT JOIN information_schema.tables_config c 
                ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
                WHERE t.TABLE_TYPE = 'BASE TABLE'
            """
            if table_name:
                query += " AND t.TABLE_NAME = %s"
                results = self.execute_query(query, (table_name,))
            else:
                results = self.execute_query(query)

            if results:
                for row in results:
                    db_name = row['TABLE_SCHEMA']
                    if db_name not in schema_info:
                        schema_info[db_name] = {}
                    
                    table_name = row['TABLE_NAME']
                    table_info = {
                        'table_id': row['TABLE_ID']
                    }

                    # Get CREATE TABLE statement
                    create_table = self.execute_query(f"SHOW CREATE TABLE `{db_name}`.`{table_name}`")
                    if create_table:
                        table_info['create_table'] = create_table[0]['Create Table']

                    # Try to get partition info and data size from information_schema.partitions_meta first
                    try:
                        meta_query = """
                            SELECT PARTITION_NAME, DATA_SIZE, ROW_COUNT 
                            FROM information_schema.partitions_meta 
                            WHERE DB_NAME = %s AND TABLE_NAME = %s
                        """
                        meta_results = self.execute_query(meta_query, (db_name, table_name))
                        if meta_results:
                            # Convert data sizes to MB
                            for partition in meta_results:
                                if partition['DATA_SIZE']:
                                    partition['DATA_SIZE_MB'] = self._convert_to_mb(partition['DATA_SIZE'])
                            table_info['partitions'] = meta_results
                            # Calculate total data size and row count
                            total_data_size = sum(p['DATA_SIZE_MB'] for p in meta_results if 'DATA_SIZE_MB' in p)
                            total_row_count = sum(int(p['ROW_COUNT']) for p in meta_results if p['ROW_COUNT'])
                            table_info['total_data_size_mb'] = total_data_size
                            table_info['total_row_count'] = total_row_count
                    except Exception as e:
                        print(f"Warning: Could not get partition info from information_schema.partitions_meta: {e}")
                        try:
                            # Fallback to SHOW PARTITIONS
                            partitions = self.execute_query(f"SHOW PARTITIONS FROM `{db_name}`.`{table_name}`")
                            table_info['partitions'] = partitions if partitions else []
                            # Get tablets if applicable
                            tablets = self.execute_query(f"SHOW TABLETS FROM `{db_name}`.`{table_name}`")
                            table_info['tablets'] = tablets if tablets else []
                            
                            # Try to get row count
                            row_count = self.execute_query(f"SELECT COUNT(*) AS count FROM `{db_name}`.`{table_name}`")
                            if row_count:
                                table_info['total_row_count'] = row_count[0]['count']
                        except:
                            pass  # Skip if we can't get row count

                    schema_info[db_name][table_name] = table_info

            return schema_info
        except Exception as e:
            print(f"Error collecting table information: {e}")
            return {}

    def _get_all_dependencies(self, db_name, mv_name, visited=None):
        """Get all dependencies for a materialized view, including nested dependencies
        Args:
            db_name: Database name
            mv_name: Materialized view name
            visited: Set of already visited objects to prevent cycles
        Returns:
            dict: Dictionary containing all dependencies
        """
        if visited is None:
            visited = set()
        
        # Create a unique identifier for this object
        obj_id = f"{db_name}.{mv_name}"
        if obj_id in visited:
            return {}  # Prevent cycles
        
        visited.add(obj_id)
        dependencies = {
            'base_tables': [],
            'materialized_views': []
        }

        try:
            # Get all dependencies
            query = """
                SELECT 
                    ref_object_database,
                    ref_object_name,
                    ref_object_type
                FROM sys.object_dependencies
                WHERE object_database = %s 
                AND object_name = %s 
                AND object_type = 'MATERIALIZED_VIEW'
            """
            results = self.execute_query(query, (db_name, mv_name))
            
            if results:
                for row in results:
                    ref_db = row['ref_object_database']
                    ref_name = row['ref_object_name']
                    ref_type = row['ref_object_type']
                    
                    if ref_type != 'MATERIALIZED_VIEW':
                        # Add base table to dependencies
                        if not any(bt['database'] == ref_db and bt['name'] == ref_name 
                                 for bt in dependencies['base_tables']):
                            dependencies['base_tables'].append({
                                'database': ref_db,
                                'name': ref_name,
                                'type': ref_type
                            })
                    elif ref_type == 'MATERIALIZED_VIEW':
                        # Get the nested MV's dependencies
                        mv_deps = self._get_all_dependencies(ref_db, ref_name, visited)
                        
                        # Add this MV to the list with its own dependencies
                        dependencies['materialized_views'].append({
                            'database': ref_db,
                            'name': ref_name,
                            'type': ref_type,
                            'dependencies': mv_deps
                        })
                        
                        # Add all nested MVs' base tables to the main base_tables list
                        if 'materialized_views' in mv_deps:
                            for nested_mv in mv_deps['materialized_views']:
                                if 'dependencies' in nested_mv and 'base_tables' in nested_mv['dependencies']:
                                    for base_table in nested_mv['dependencies']['base_tables']:
                                        if not any(bt['database'] == base_table['database'] and 
                                                 bt['name'] == base_table['name'] 
                                                 for bt in dependencies['base_tables']):
                                            dependencies['base_tables'].append(base_table)
            
            return dependencies
        except Exception as e:
            print(f"Error getting dependencies for {db_name}.{mv_name}: {e}")
            return dependencies

    def collect_mv_info(self, mv_name=None):
        """Collect materialized view information including schema, task name and refresh history
        Args:
            mv_name: Optional. If specified, only collect info for this materialized view
        """
        try:
            # Connect to leader FE
            leader_fe = self.get_leader_fe()
            if not leader_fe:
                print("Error: Could not find leader FE")
                return {}

            # Switch connection to leader FE
            if self.connection:
                self.connection.close()
            self.host = leader_fe
            if not self.connect():
                return {}

            mv_info = {}
            query = """
                SELECT 
                    TABLE_SCHEMA,
                    TABLE_NAME,
                    MATERIALIZED_VIEW_DEFINITION,
                    TASK_NAME
                FROM information_schema.materialized_views
            """
            if mv_name:
                query += " WHERE TABLE_NAME = %s"
                results = self.execute_query(query, (mv_name,))
            else:
                results = self.execute_query(query)

            if results:
                for row in results:
                    db_name = row['TABLE_SCHEMA']
                    if db_name not in mv_info:
                        mv_info[db_name] = {}

                    mv_name = row['TABLE_NAME']
                    mv_info[db_name][mv_name] = {
                        'definition': row['MATERIALIZED_VIEW_DEFINITION'],
                        'task_name': row['TASK_NAME']
                    }

                    # Get latest refresh history
                    task_name = row['TASK_NAME']
                    if task_name and task_name.strip():  # Check if task_name exists and is not empty
                        try:
                            refresh_history = self.execute_query("""
                                SELECT 
                                    QUERY_ID,
                                    DATE_FORMAT(FINISH_TIME, '%%Y-%%m-%%d %%H:%%i:%%s') as FINISH_TIME,
                                    State,
                                    ERROR_MESSAGE
                                FROM information_schema.task_runs
                                WHERE TASK_NAME = %s
                                ORDER BY FINISH_TIME DESC
                                LIMIT 1
                            """, (task_name,))
                            mv_info[db_name][mv_name]['latest_refresh'] = refresh_history[0] if refresh_history else None
                        except Exception as e:
                            print(f"Warning: Could not get refresh history for {db_name}.{mv_name}: {e}")
                            mv_info[db_name][mv_name]['latest_refresh'] = None
                    else:
                        mv_info[db_name][mv_name]['latest_refresh'] = None

                    # Get all dependencies including nested ones
                    dependencies = self._get_all_dependencies(db_name, mv_name)
                    mv_info[db_name][mv_name]['dependencies'] = dependencies

                    # Try to get partition info and data size from information_schema.partitions_meta first
                    try:
                        meta_query = """
                            SELECT PARTITION_NAME, DATA_SIZE, ROW_COUNT 
                            FROM information_schema.partitions_meta 
                            WHERE DB_NAME = %s AND TABLE_NAME = %s
                        """
                        meta_results = self.execute_query(meta_query, (db_name, mv_name))
                        if meta_results:
                            # Convert data sizes to MB
                            for partition in meta_results:
                                if partition['DATA_SIZE']:
                                    partition['DATA_SIZE_MB'] = self._convert_to_mb(partition['DATA_SIZE'])
                            mv_info[db_name][mv_name]['partitions'] = meta_results
                            # Calculate total data size and row count
                            total_data_size = sum(p['DATA_SIZE_MB'] for p in meta_results if 'DATA_SIZE_MB' in p)
                            total_row_count = sum(int(p['ROW_COUNT']) for p in meta_results if p['ROW_COUNT'])
                            mv_info[db_name][mv_name]['total_data_size_mb'] = total_data_size
                            mv_info[db_name][mv_name]['total_row_count'] = total_row_count
                    except Exception as e:
                        print(f"Warning: Could not get partition info from information_schema.partitions_meta: {e}")
                        # Fallback to SHOW PARTITIONS
                        mv_partitions = self.execute_query(f"SHOW PARTITIONS FROM `{db_name}`.`{mv_name}`")
                        mv_info[db_name][mv_name]['partitions'] = mv_partitions if mv_partitions else []

            return mv_info
        except Exception as e:
            print(f"Error collecting materialized view information: {e}")
            return {}

    def collect_tablet_metadata(self, tablet_id=None):
        """Collect tablet metadata information including three replicas
        Args:
            tablet_id: Optional. If specified, only collect info for this tablet
        """
        try:
            # Connect to leader FE
            leader_fe = self.get_leader_fe()
            if not leader_fe:
                print("Error: Could not find leader FE")
                return {}

            # Switch connection to leader FE
            self.connection.close()
            self.host = leader_fe
            if not self.connect():
                return {}

            tablet_info = {}
            query = "SHOW PROC '/tablets'"
            if tablet_id:
                query += f" WHERE TabletId = {tablet_id}"
            
            results = self.execute_query(query)
            if results:
                for row in results:
                    tablet_id = row['TabletId']
                    tablet_info[tablet_id] = {
                        'replicas': [],
                        'schema_hash': row.get('SchemaHash'),
                        'state': row.get('State'),
                        'data_size': row.get('DataSize'),
                        'row_count': row.get('RowCount')
                    }
                    
                    # Get replica information
                    replica_query = f"SHOW PROC '/tablets/{tablet_id}'"
                    replicas = self.execute_query(replica_query)
                    if replicas:
                        tablet_info[tablet_id]['replicas'] = replicas

            return tablet_info
        except Exception as e:
            print(f"Error collecting tablet metadata: {e}")
            return {}

    def get_backend_ip_by_id(self, backend_id):
        """Get backend IP by backend ID
        Args:
            backend_id: The backend ID to look up
        Returns:
            str: The backend IP address, or None if not found
        """
        try:
            host_id_mapping = self.get_backend_host_id_mapping()
            # Reverse the mapping to find host by id
            id_host_mapping = {v: k for k, v in host_id_mapping.items()}
            return id_host_mapping.get(backend_id)
        except Exception as e:
            print(f"Error getting backend IP: {e}")
            return None

    def check_and_set_bad_replica(self, tablet_id):
        """Check if tablet has three replicas and set bad replica if needed
        Args:
            tablet_id: The tablet ID to check
        Returns:
            bool: True if operation was successful, False otherwise
        """
        try:
            # Connect to leader FE
            leader_fe = self.get_leader_fe()
            if not leader_fe:
                print("Error: Could not find leader FE")
                return False

            # Switch connection to leader FE
            if self.connection:
                self.connection.close()
            self.host = leader_fe
            if not self.connect():
                return False

            # Get tablet information
            tablet_query = f"SHOW TABLET {tablet_id}"
            tablet_info = self.execute_query(tablet_query)
            
            if not tablet_info:
                print(f"Error: No information found for tablet {tablet_id}")
                return False

            # Get DetailCmd and execute it to get replica information
            detail_cmd = tablet_info[0].get('DetailCmd')
            if not detail_cmd:
                print(f"Error: No DetailCmd found for tablet {tablet_id}")
                return False

            replicas = self.execute_query(detail_cmd)
            if not replicas:
                print(f"Error: No replicas found for tablet {tablet_id}")
                return False

            # Check if we have at least three replicas
            if len(replicas) < 3:
                print(f"Error: Tablet {tablet_id} does not have at least three replicas. Found {len(replicas)} replicas.")
                return False

            # Counter to ensure only one set bad operation is executed
            set_bad_count = 0

            # Check each replica for issues
            for replica in replicas:
                if set_bad_count > 0:
                    break  # Skip remaining replicas if we've already set one as bad

                if replica.get('LstFailedVersion') != '-1' or replica.get('IsErrorState') == 'true':
                    backend_id = replica.get('BackendId')
                    if not backend_id:
                        print(f"Error: Could not find BackendId for replica in tablet {tablet_id}")
                        return False

                    # Get backend IP
                    backend_ip = self.get_backend_ip_by_id(backend_id)
                    if not backend_ip:
                        print(f"Error: Could not find IP for backend {backend_id}")
                        return False

                    # Set the replica as bad
                    set_bad_cmd = f"""ADMIN SET REPLICA STATUS PROPERTIES("tablet_id" = "{tablet_id}", "backend_id" = "{backend_id}", "status" = "bad")"""
                    try:
                        self.execute_query(set_bad_cmd)
                        print(f"Successfully set replica on {backend_ip} (backend_id: {backend_id}) as bad for tablet {tablet_id}")
                        set_bad_count += 1
                        return True
                    except Exception as e:
                        print(f"Error setting bad replica: {e}")
                        return False

            if set_bad_count == 0:
                print(f"No replicas found with issues for tablet {tablet_id}")
            return True

        except Exception as e:
            print(f"Error checking and setting bad replica: {e}")
            return False

    def get_modified_session_variables(self):
        """Get modified session variables and their current values
        Returns:
            dict: Dictionary containing modified session variables and their values
        """
        try:
            # Connect to leader FE
            leader_fe = self.get_leader_fe()
            if not leader_fe:
                print("Error: Could not find leader FE")
                return {}

            # Switch connection to leader FE
            if self.connection:
                self.connection.close()
            self.host = leader_fe
            if not self.connect():
                print("Error: Could not connect leader FE")
                return {}

            # Get session variables
            query = "SELECT VARIABLE_NAME, VARIABLE_VALUE, IS_CHANGED FROM information_schema.verbose_session_variables"
            variables = self.execute_query(query)
            
            if not variables:
                print("Error: Could not get session variables")
                return {}

            # Filter and format modified variables
            modified_vars = {}
            for var in variables:
                if var['IS_CHANGED'] == 'TRUE':
                    modified_vars[var['VARIABLE_NAME']] = {
                        'current_value': var['VARIABLE_VALUE'],
                        'is_modified': True
                    }

            return modified_vars

        except Exception as e:
            print(f"Error getting modified session variables: {e}")
            return {}

    def get_modified_be_configs(self):
        """Get modified BE configurations
        Returns:
            dict: Dictionary containing modified BE configurations
        """
        try:
            # Connect to leader FE
            leader_fe = self.get_leader_fe()
            if not leader_fe:
                print("Error: Could not find leader FE")
                return {}

            # Switch connection to leader FE
            if self.connection:
                self.connection.close()
            self.host = leader_fe
            if not self.connect():
                return {}

            # Get BE configurations
            query = "SELECT BE_ID, NAME, VALUE, `DEFAULT` FROM information_schema.be_configs"
            configs = self.execute_query(query)
            
            if not configs:
                print("Error: Could not get BE configurations")
                return {}

            # Filter and format modified configurations
            modified_configs = {}
            for config in configs:
                if config['VALUE'] != config['DEFAULT']:
                    be_id = config['BE_ID']
                    be_ip = self.get_backend_ip_by_id(be_id)
                    if be_ip:
                        if be_ip not in modified_configs:
                            modified_configs[be_ip] = {}
                        
                        modified_configs[be_ip][config['NAME']] = {
                            'current_value': config['VALUE'],
                            'default_value': config['DEFAULT']
                        }

            return modified_configs

        except Exception as e:
            print(f"Error getting modified BE configurations: {e}")
            return {}

    def get_modified_fe_configs(self):
        """Get modified FE configurations
        Returns:
            dict: Dictionary containing modified FE configurations
        """
        try:
            # Connect to leader FE
            leader_fe = self.get_leader_fe()
            if not leader_fe:
                print("Error: Could not find leader FE")
                return {}

            # Switch connection to leader FE
            if self.connection:
                self.connection.close()
            self.host = leader_fe
            if not self.connect():
                return {}

            # Get FE configurations
            query = "ADMIN SHOW FRONTEND CONFIG"
            configs = self.execute_query(query)
            
            if not configs:
                print("Error: Could not get FE configurations")
                return {}

            # Format FE configurations
            fe_configs = {}
            for config in configs:
                fe_configs[config['Key']] = {
                    'value': config['Value']
                }

            return fe_configs

        except Exception as e:
            print(f"Error getting modified FE configurations: {e}")
            return {}

    def collect_all_configs(self):
        """Collect all configurations including FE configs, BE configs and session variables
        Returns:
            dict: Dictionary containing all configurations
        """
        try:
            all_configs = {
                'fe_configs': self.get_modified_fe_configs(),
                'be_configs': self.get_modified_be_configs(),
                'session_vars': self.get_modified_session_variables()
            }
            return all_configs
        except Exception as e:
            print(f"Error collecting all configurations: {e}")
            return {}

    def get_backend_host_id_mapping(self):
        """Get mapping between backend host and backend id
        Returns:
            dict: Dictionary containing backend host to id mapping
        """
        try:
            # Connect to leader FE
            leader_fe = self.get_leader_fe()
            if not leader_fe:
                print("Error: Could not find leader FE")
                return {}

            # Switch connection to leader FE
            if self.connection:
                self.connection.close()
            self.host = leader_fe
            if not self.connect():
                return {}

            # Get backend information
            query = "SHOW PROC '/backends'"
            backends = self.execute_query(query)
            
            if not backends:
                print("Error: Could not get backend information")
                return {}

            # Create mapping
            host_id_mapping = {}
            for backend in backends:
                host = backend.get('IP')
                backend_id = backend.get('BackendId')
                if host and backend_id:
                    host_id_mapping[host] = backend_id
            print(f"Backend host-id mapping: {host_id_mapping}")

            return host_id_mapping

        except Exception as e:
            print(f"Error getting backend host-id mapping: {e}")
            return {}

    def get_query_dump(self, sql_file):
        """Get query dump for SQL statements in a file
        Args:
            sql_file: Path to the SQL file
        Returns:
            dict: Dictionary containing query dumps
        """
        try:
            if not os.path.exists(sql_file):
                print(f"Error: SQL file {sql_file} does not exist")
                return {}

            # Read SQL file
            with open(sql_file, 'r') as f:
                sql_content = f.read()

            # Get query dump
            query = "SELECT get_query_dump(%s)"
            result = self.execute_query(query, (sql_content,))
            
            if result:
                return {
                    'sql_file': sql_file,
                    'query_dump': result[0]['get_query_dump']
                }
            return {}
        except Exception as e:
            print(f"Error getting query dump: {e}")
            return {}

    def get_be_stack_trace(self, be_ip):
        """Get stack trace for all threads on a BE node
        Args:
            be_ip: BE node IP address
        Returns:
            dict: Dictionary containing stack trace information
        """
        try:
            # Get BE ID from IP
            host_id_mapping = self.get_backend_host_id_mapping()
            be_id = host_id_mapping.get(be_ip)
            
            if not be_id:
                print(f"Error: Could not find BE ID for IP {be_ip}")
                return {}

            # Execute stack trace command
            query = f"ADMIN EXECUTE ON {be_id} 'System.print(ExecEnv.get_stack_trace_for_all_threads())'"
            result = self.execute_query(query)
            
            if result:
                return {
                    'be_ip': be_ip,
                    'be_id': be_id,
                    'stack_trace': result[0]['result']
                }
            return {}
        except Exception as e:
            print(f"Error getting BE stack trace: {e}")
            return {}

    def check_empty_partitions(self, limit=100):
        """检查数据为空的表或分区，按空分区个数倒序排序
        
        Args:
            limit: 返回结果数量限制
            
        Returns:
            list: 空分区信息列表
        """
        try:
            query = """
                SELECT 
                    DB_NAME,
                    TABLE_NAME,
                    COUNT(*) as empty_partition_count,
                    GROUP_CONCAT(PARTITION_NAME) as empty_partitions
                FROM information_schema.partitions_meta
                WHERE ROW_COUNT = 0 OR ROW_COUNT IS NULL
                GROUP BY DB_NAME, TABLE_NAME
                ORDER BY empty_partition_count DESC
                LIMIT %s
            """
            return self.execute_query(query, (limit,))
        except Exception as e:
            print(f"Error checking empty partitions: {e}")
            return []

    def check_single_replica_tables(self):
        """检查单副本的表
        
        Returns:
            list: 单副本表信息列表
        """
        try:
            query = """
                SELECT 
                    DB_NAME,
                    TABLE_NAME,
                    REPLICATION_NUM
                FROM information_schema.partitions_meta
                WHERE REPLICATION_NUM = 1
                GROUP BY DB_NAME, TABLE_NAME, REPLICATION_NUM
            """
            return self.execute_query(query)
        except Exception as e:
            print(f"Error checking single replica tables: {e}")
            return []

    def check_single_bucket_large_tables(self, size_gb=1):
        """检查单bucket且数据量超过指定大小的表或分区
        
        Args:
            size_gb: 数据量阈值（GB）
            
        Returns:
            list: 符合条件的表信息列表
        """
        try:
            query = """
                SELECT 
                    DB_NAME,
                    TABLE_NAME,
                    PARTITION_NAME,
                    BUCKETS,
                    DATA_SIZE
                FROM information_schema.partitions_meta
                WHERE BUCKETS = 1
                AND CAST(REGEXP_REPLACE(DATA_SIZE, '[^0-9.]', '') AS DECIMAL) > %s * 1024 * 1024 * 1024
            """
            return self.execute_query(query, (size_gb,))
        except Exception as e:
            print(f"Error checking single bucket large tables: {e}")
            return []

    def check_unpartitioned_large_tables(self, size_gb=50):
        """检查未分区且数据量超过指定大小的表
        
        Args:
            size_gb: 数据量阈值（GB）
            
        Returns:
            list: 符合条件的表信息列表
        """
        try:
            query = """
                SELECT 
                    t.DB_NAME,
                    t.TABLE_NAME,
                    SUM(CAST(REGEXP_REPLACE(p.DATA_SIZE, '[^0-9.]', '') AS DECIMAL)) as total_size
                FROM information_schema.tables_config t
                JOIN information_schema.partitions_meta p 
                ON t.TABLE_SCHEMA = p.DB_NAME AND t.TABLE_NAME = p.TABLE_NAME
                WHERE t.PARTITION_KEY IS NULL OR t.PARTITION_KEY = ''
                GROUP BY t.DB_NAME, t.TABLE_NAME
                HAVING total_size > %s * 1024 * 1024 * 1024
            """
            return self.execute_query(query, (size_gb,))
        except Exception as e:
            print(f"Error checking unpartitioned large tables: {e}")
            return []

    def check_tables_without_index_disk(self):
        """检查没有开启索引落盘的表
        
        Returns:
            list: 符合条件的表信息列表
        """
        try:
            query = """
                WITH TableDataSize AS (
                    -- 计算每个表的数据大小
                    SELECT
                        pm.DB_NAME,
                        pm.TABLE_NAME,
                        COALESCE(SUM(tbt.DATA_SIZE), 0) / (1024 * 1024 * 1024) AS total_data_size_gb  -- 转换为 GB
                    FROM
                        information_schema.partitions_meta pm
                    LEFT JOIN
                        information_schema.be_tablets tbt ON pm.PARTITION_ID = tbt.PARTITION_ID
                    GROUP BY
                        pm.DB_NAME,
                        pm.TABLE_NAME
                )
                SELECT
                    tc.TABLE_SCHEMA AS "database_name",
                    tc.TABLE_NAME AS "table_name",
                    tc.properties,
                    td.total_data_size_gb AS "data_size_gb",  -- 数据大小
                    td.total_data_size_gb * 0.15 AS "estimated_memory_usage_gb"  -- 估算内存占用（假设为数据大小的 15%）
                FROM
                    information_schema.tables_config tc
                LEFT JOIN
                    TableDataSize td ON tc.TABLE_SCHEMA = td.DB_NAME AND tc.TABLE_NAME = td.TABLE_NAME
                WHERE
                    tc.table_model = "PRIMARY_KEYS"
                    AND tc.properties LIKE '%enable_persistent_index":"false"%'
                ORDER BY
                    td.total_data_size_gb DESC
            """
            return self.execute_query(query)
        except Exception as e:
            print(f"Error checking tables without index disk: {e}")
            return []

    def check_large_tablets(self, size_gb=5):
        """检查单个tablet数据量超过指定大小的表或分区
        
        Args:
            size_gb: 数据量阈值（GB）
            
        Returns:
            list: 符合条件的tablet信息列表
        """
        try:
            # 首先尝试从 be_tablets 获取数据
            query = """
                SELECT 
                    t.DB_NAME,
                    t.TABLE_NAME,
                    bt.TABLET_ID,
                    bt.DATA_SIZE
                FROM information_schema.be_tablets bt
                JOIN information_schema.tables_config t 
                ON bt.TABLE_ID = t.TABLE_ID
                WHERE bt.DATA_SIZE > %s * 1024 * 1024 * 1024
            """
            result = self.execute_query(query, (size_gb,))
            
            if not result:
                # 如果从 be_tablets 获取失败，尝试从 show tablet 获取
                tables = self.execute_query("""
                    SELECT DISTINCT TABLE_SCHEMA, TABLE_NAME 
                    FROM information_schema.tables_config
                """)
                
                large_tablets = []
                for table in tables:
                    tablets = self.execute_query(f"SHOW TABLETS FROM `{table['TABLE_SCHEMA']}`.`{table['TABLE_NAME']}`")
                    for tablet in tablets:
                        if tablet.get('DataSize'):
                            size = self._convert_to_mb(tablet['DataSize'])
                            if size > size_gb * 1024:  # 转换为MB
                                large_tablets.append({
                                    'DB_NAME': table['TABLE_SCHEMA'],
                                    'TABLE_NAME': table['TABLE_NAME'],
                                    'TABLET_ID': tablet['TabletId'],
                                    'DATA_SIZE': tablet['DataSize']
                                })
                return large_tablets
                
            return result
        except Exception as e:
            print(f"Error checking large tablets: {e}")
            return []

    def check_tablets_with_many_versions(self, version_threshold=900):
        """检查tablet版本个数超过阈值的tablet
        
        Args:
            version_threshold: 版本数阈值
            
        Returns:
            list: 符合条件的tablet信息列表
        """
        try:
            query = """
                SELECT 
                    t.DB_NAME,
                    t.TABLE_NAME,
                    bt.TABLET_ID,
                    bt.NUM_ROWSET
                FROM information_schema.be_tablets bt
                JOIN information_schema.tables_config t 
                ON bt.TABLE_ID = t.TABLE_ID
                WHERE bt.NUM_ROWSET > %s
            """
            return self.execute_query(query, (version_threshold,))
        except Exception as e:
            print(f"Error checking tablets with many versions: {e}")
            return []

    def check_small_tablets(self, size_mb=500, limit=100):
        """检查单个tablet数据量小于指定大小的表或分区，按tablet个数排序
        
        Args:
            size_mb: 数据量阈值（MB）
            limit: 返回结果数量限制
            
        Returns:
            list: 符合条件的表信息列表
        """
        try:
            # 首先尝试从 be_tablets 获取数据
            query = """
                SELECT 
                    t.DB_NAME,
                    t.TABLE_NAME,
                    COUNT(*) as small_tablet_count,
                    GROUP_CONCAT(bt.TABLET_ID) as tablet_ids
                FROM information_schema.be_tablets bt
                JOIN information_schema.tables_config t 
                ON bt.TABLE_ID = t.TABLE_ID
                WHERE bt.DATA_SIZE < %s * 1024 * 1024
                GROUP BY t.DB_NAME, t.TABLE_NAME
                ORDER BY small_tablet_count DESC
                LIMIT %s
            """
            result = self.execute_query(query, (size_mb, limit))
            
            if not result:
                # 如果从 be_tablets 获取失败，尝试从 show tablet 获取
                tables = self.execute_query("""
                    SELECT DISTINCT TABLE_SCHEMA, TABLE_NAME 
                    FROM information_schema.tables_config
                """)
                
                small_tablets = {}
                for table in tables:
                    tablets = self.execute_query(f"SHOW TABLETS FROM `{table['TABLE_SCHEMA']}`.`{table['TABLE_NAME']}`")
                    small_count = 0
                    tablet_ids = []
                    
                    for tablet in tablets:
                        if tablet.get('DataSize'):
                            size = self._convert_to_mb(tablet['DataSize'])
                            if size < size_mb:
                                small_count += 1
                                tablet_ids.append(tablet['TabletId'])
                    
                    if small_count > 0:
                        small_tablets[f"{table['TABLE_SCHEMA']}.{table['TABLE_NAME']}"] = {
                            'DB_NAME': table['TABLE_SCHEMA'],
                            'TABLE_NAME': table['TABLE_NAME'],
                            'small_tablet_count': small_count,
                            'tablet_ids': ','.join(map(str, tablet_ids))
                        }
                
                # 按small_tablet_count排序并返回前limit个结果
                return sorted(small_tablets.values(), key=lambda x: x['small_tablet_count'], reverse=True)[:limit]
                
            return result
        except Exception as e:
            print(f"Error checking small tablets: {e}")
            return []

    def get_yesterdays_tables(self):
        """获取昨天新建的表信息"""
        try:
            # 获取昨天的日期字符串
            yesterday = (datetime.now() - timedelta(days=1)).strftime('%Y-%m-%d')
            today = datetime.now().strftime('%Y-%m-%d')
            query = f"""
                SELECT TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_ROWS, DATA_LENGTH, CREATE_TIME
                FROM information_schema.tables
                WHERE CREATE_TIME >= '{yesterday} 00:00:00' AND CREATE_TIME < '{today} 00:00:00'
            """
            return self.execute_query(query)
        except Exception as e:
            print(f"Error getting yesterday's tables: {e}")
            return []


    def get_fe_log_paths(self):
        """Get log paths for all FE nodes"""
        try:
            fe_nodes = self.execute_query("SHOW PROC '/frontends'")
            if not fe_nodes:
                print("Error: Could not get FE nodes information")
                return {}

            log_paths = {}
            original_host = self.host

            for fe in fe_nodes:
                fe_host = fe['IP']
                try:
                    if self.connection and self.connection.is_connected():
                        self.connection.close()
                    self.host = fe_host
                    if not self.connect():
                        print(f"Warning: Could not connect to FE {fe_host}:{self.port}")
                        log_paths[fe_host] = "Connection Failed"
                        continue

                    query = "ADMIN SHOW FRONTEND CONFIG LIKE 'sys_log_dir'"
                    log_config = self.execute_query(query)
                    if log_config:
                        log_paths[fe_host] = log_config[0]['Value']
                    else:
                        log_paths[fe_host] = "Not Found"

                except Error as e:
                    print(f"Error collecting log path from FE {fe_host}: {e}")
                    log_paths[fe_host] = f"Error: {e}"
                finally:
                    if self.connection and self.connection.is_connected():
                        self.connection.close()

            # Restore original connection
            self.host = original_host
            if not self.connect():
                print("Error: Could not restore connection to original FE")

            return log_paths
        except Error as e:
            print(f"Error getting FE log paths: {e}")
            return {}

    def get_be_log_paths(self):
        """Get log paths for all BE nodes"""
        try:
            query = "select BE_ID, VALUE from information_schema.be_configs where NAME = 'sys_log_dir'"
            results = self.execute_query(query)
            if results is None:
                print("Could not retrieve BE log paths.")
                return {}

            host_id_mapping = self.get_backend_host_id_mapping()
            id_host_mapping = {v: k for k, v in host_id_mapping.items()}

            log_paths = {}
            for row in results:
                be_id = str(row['BE_ID'])
                log_path = row['VALUE']
                be_ip = id_host_mapping.get(be_id, f"Unknown BE ID: {be_id}")
                log_paths[be_ip] = log_path
            print(f"BE log paths: {log_paths}")

            return log_paths
        except Error as e:
            print(f"Error getting BE log paths: {e}")
            return {}

    def check_manager_logs(self):
        """Check manager logs for errors"""
        try:
            # Find the manager directory by inspecting the drms process
            command = "ps aux | grep '[d]rms'"
            # Using text=True for Python 3.7+
            result = subprocess.run(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, check=False)

            if result.returncode != 0 or not result.stdout:
                return "Manager 'drms' process not found."

            process_line = result.stdout.strip().split('\n')[0]

            # The command can have spaces. `ps aux` format: USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
            # The command starts at column 11.
            parts = process_line.split(None, 10)
            if len(parts) < 11:
                return f"Could not parse 'ps' output for drms process: {process_line}"

            command_full = parts[10]

            manager_dir = None
            # Try to extract from executable path first
            # e.g., /home/disk1/manager-20250113/center/lib/web/drms
            executable_path = command_full.split()[0]
            match = re.search(r'(.*/center)/lib/web/drms', executable_path)
            if match:
                manager_dir = match.group(1)
            else:
                # If not found, try to extract from --log_dir argument
                # e.g., --log_dir=/home/disk1/manager-20250113/center/log/web
                match = re.search(r'--log_dir=([^\s]+)', command_full)
                if match:
                    log_dir = match.group(1)
                    # manager_dir is two levels up from log_dir
                    center_dir = os.path.dirname(os.path.dirname(log_dir))
                    if os.path.basename(center_dir) == 'center':
                        manager_dir = center_dir

            if not manager_dir or not os.path.isdir(manager_dir):
                return f"Manager directory not found or is not a directory. Determined path: {manager_dir}. Process info: {command_full}"

            # Use the same output directory structure as remote_diagnostics
            run_output_dir = os.path.join(self.output_dir, f"remote_diagnostics_{self.timestamp}")
            output_dir = os.path.join(run_output_dir, "manager_logs")
            os.makedirs(output_dir, exist_ok=True)

            drms_warning_cmd = f"grep -E 'E[0-9]{{4,}}' {manager_dir}/log/web/drms.WARNING > {output_dir}/drms.WARNING"
            center_service_warning_cmd = f"grep -E 'E[0-9]{{4,}}' {manager_dir}/log/center-service/center_service.WARNING > {output_dir}/center_service.WARNING"

            os.system(drms_warning_cmd)
            os.system(center_service_warning_cmd)

            return f"Manager logs checked. Output saved in {output_dir}"
        except Exception as e:
            return f"Error checking manager logs: {e}"

    def get_proc_statistic(self):
        """Get SHOW PROC '/statistic' result"""
        results = self.execute_query("SHOW PROC '/statistic'")
        if not results:
            return {}

        processed_stats = {}
        for row in results:
            db_name = row.get('DbName')
            if not db_name:
                continue

            # Basic statistics for each database
            db_stats = {
                'DbId': row.get('DbId'),
                'TableNum': row.get('TableNum'),
                'PartitionNum': row.get('PartitionNum'),
                'IndexNum': row.get('IndexNum'),
                'TabletNum': row.get('TabletNum'),
                'ReplicaNum': row.get('ReplicaNum'),
            }

            # Fields to check for non-zero values
            unhealthy_fields = [
                'UnhealthyTabletNum',
                'InconsistentTabletNum',
                'CloningTabletNum',
                'ErrorStateTabletNum'
            ]

            for field in unhealthy_fields:
                value = row.get(field)
                if value and int(value) > 0:
                    db_stats[field] = value
            
            processed_stats[db_name] = db_stats

        return processed_stats

    def _fetch_remote_file(self, ip, ssh_port, remote_path, local_path):
        """Helper to fetch a single file using scp."""
        try:
            print(f"  Fetching {remote_path} from {ip} to {local_path}")
            command = [
                'scp', '-P', str(ssh_port),
                '-o', 'StrictHostKeyChecking=no',
                '-o', 'UserKnownHostsFile=/dev/null',
                f'{ip}:{remote_path}',
                local_path
            ]
            subprocess.run(command, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=60)
            return True
        except subprocess.CalledProcessError as e:
            print(f"  Could not fetch {remote_path} with scp: {e.stderr}")
            return False
        except Exception as e:
            print(f"  An error occurred while fetching {remote_path}: {e}")
            return False


    def _execute_remote_cmd_and_save_output(self, ip, ssh_port, cmd, local_path):
        """Executes a command on the remote host and saves stdout to a local file."""
        try:
            print(f"  Executing remote command on {ip}: {cmd}")
            ssh_command = [
                'ssh', '-p', str(ssh_port),
                '-o', 'StrictHostKeyChecking=no',
                '-o', 'UserKnownHostsFile=/dev/null',
                ip,
                cmd
            ]
            result = subprocess.run(ssh_command, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=30)
            output = result.stdout
            error = result.stderr

            # Log stderr unless it's a "file not found" error, which is common
            if error and "No such file or directory" not in error:
                print(f"  Stderr from remote command: {error.strip()}")

            with open(local_path, 'w', encoding='utf-8') as f:
                f.write(output)

            print(f"  Saved output to {local_path}")
            return True
        except Exception as e:
            print(f"  Failed to execute remote command on {ip} '{cmd}': {e}")
            return False

    def collect_data_from_all_nodes(self, ssh_port=22, fe_http_port=8030, be_http_port=8040):
        """
        Collects diagnostic data from all FE and BE nodes via SSH.
        This includes log files, configuration files, and system files.
        """
        all_nodes = {}
        try:
            fe_nodes = self.get_fes()
            be_nodes = list(self.get_backend_host_id_mapping().keys())
        except Exception as e:
            print(f"Error getting node list: {e}. Please ensure the initial connection is to a valid FE.")
            return {}
        
        print(f"FE nodes: {fe_nodes}")
        print(f"BE nodes: {be_nodes}")

        for ip in fe_nodes:
            all_nodes[ip] = 'fe'
        for ip in be_nodes:
            # A node can be both FE and BE
            if ip not in all_nodes:
                all_nodes[ip] = 'be'

        all_results = {}
        
        # Create a main directory for this run
        run_output_dir = os.path.join(self.output_dir, f"remote_diagnostics_{self.timestamp}")
        os.makedirs(run_output_dir, exist_ok=True)
        print(f"Saving remote diagnostics to: {run_output_dir}")

        fes_log_dir = self.get_fe_log_paths()
        bes_log_dir = self.get_be_log_paths()

        for ip, role in all_nodes.items():
            print(f"\nCollecting data from {role} node: {ip}...")
            node_results = {}
            try:
                # 1. Get log and conf directories
                log_dir = None
                conf_dir = None
                if role == "fe":
                    log_dir = fes_log_dir[ip]
                else:
                    log_dir = bes_log_dir[ip]

                if log_dir:
                    conf_dir = os.path.join(os.path.dirname(log_dir), 'conf')
                    node_results['log_dir'] = log_dir
                    node_results['conf_dir'] = conf_dir
                else:
                    print(f"  Could not determine log directory for {ip}.")

                # 2. Fetch files
                node_output_dir = os.path.join(run_output_dir, f"{ip}_{role}")
                os.makedirs(node_output_dir, exist_ok=True)

                self._fetch_remote_file(ip, ssh_port, '/etc/hosts', os.path.join(node_output_dir, 'hosts.txt'))
                self._fetch_remote_file(ip, ssh_port, '/etc/fstab', os.path.join(node_output_dir, 'fstab.txt'))

                if conf_dir:
                    self._fetch_remote_file(ip, ssh_port, os.path.join(conf_dir, f'{role}.conf'), os.path.join(node_output_dir, f'{role}.conf'))



                # 3. Execute remote checks and save filtered logs
                if log_dir:
                    if role == 'fe':
                        # check_fe_logs
                        log_file = os.path.join(log_dir, 'fe.warn.log')
                        output_file = os.path.join(node_output_dir, "fe_warn_filtered.log")
                        cmd = f"grep -i -E 'error|exception' {log_file}"
                        self._execute_remote_cmd_and_save_output(ip, ssh_port, cmd, output_file)
                    else: # be
                        # check_be_out
                        log_file = os.path.join(log_dir, 'be.out')
                        output_file = os.path.join(node_output_dir, "be_out_filtered.log")
                        cmd = f"sed -n '/3.3.14-ee RELEASE (build 5b29ea9)/,/start time/p' {log_file}"
                        self._execute_remote_cmd_and_save_output(ip, ssh_port, cmd, output_file)

                        # check_be_warning_logs
                        log_file = os.path.join(log_dir, 'be.WARNING')
                        output_file = os.path.join(node_output_dir, "be_warning_filtered.log")
                        cmd = f"grep -i -E 'error|fail' {log_file}"
                        self._execute_remote_cmd_and_save_output(ip, ssh_port, cmd, output_file)

                        # check_task_queue
                        log_file = os.path.join(log_dir, 'be.INFO')
                        output_file = os.path.join(node_output_dir, "task_queue_filtered.log")
                        cmd = f"grep -E 'task_count_in_queue=[2-9][0-9]{{4,}}' {log_file}"
                        self._execute_remote_cmd_and_save_output(ip, ssh_port, cmd, output_file)
                
                node_results['status'] = 'Success'
                node_results['collected_files_path'] = node_output_dir
                all_results[ip] = node_results

            except Exception as e:
                print(f"Failed to collect data from {ip}: {e}")
                all_results[ip] = {'status': 'Failed', 'error': str(e)}
        
        return all_results

def main():
    parser = argparse.ArgumentParser(description='StarRocks Diagnostic Tool')
    parser.add_argument('--host', required=True, help='FE hostname or endpoint')
    parser.add_argument('--port', type=int, default=9030, help='FE port (default: 9030)')
    parser.add_argument('--user', required=True, help='Username')
    parser.add_argument('--password', required=True, help='Password')
    parser.add_argument('--output', default='./starrocks_diagnostic', help='Output directory')
    parser.add_argument('--format', choices=['json', 'csv', 'yaml', 'txt'], default='json',
                      help='Output format (default: json)')
    parser.add_argument('--module', choices=['schema', 'mv', 'tablet', 'check_replica', 'session_vars', 'be_config', 'fe_config', 'all_configs', 'backend_mapping', 'cluster_state', 'performance_diagnostics', 'query_dump', 'be_stack', 'yesterdays_tables', 'log_paths', 'remote_diagnostics'], required=True, 
                      help='Module to run: schema, mv, tablet, check_replica, session_vars, be_config, fe_config, all_configs, backend_mapping, cluster_state, performance_diagnostics, query_dump, be_stack, yesterdays_tables, log_paths, remote_diagnostics (collect logs/confs from all nodes via SSH)')
    parser.add_argument('--name', help='Optional. Table name, MV name, tablet ID or replica ID to collect info for')
    parser.add_argument('--sql_file', help='Path to SQL file for query_dump module')
    parser.add_argument('--be_ip', help='BE IP address for be_stack module')
    parser.add_argument('--size_gb', type=float, help='Size threshold in GB for large tablets check')
    parser.add_argument('--size_mb', type=float, help='Size threshold in MB for small tablets check')
    parser.add_argument('--version_threshold', type=int, default=900, help='Version threshold for tablets with many versions check')
    parser.add_argument('--ssh_port', type=int, default=22, help='SSH port (default: 22)')

    args = parser.parse_args()

    doctor = StarRocksDoctor(
        host=args.host,
        port=args.port,
        user=args.user,
        password=args.password,
        output_dir=args.output
    )

    if not doctor.connect():
        return

    try:
        if args.module == 'schema':
            result = doctor.collect_table_info(args.name)
            doctor.save_to_file(result, 'table_info', args.format)
        elif args.module == 'mv':
            result = doctor.collect_mv_info(args.name)
            doctor.save_to_file(result, 'materialized_view_info', args.format)
        elif args.module == 'tablet':
            if args.name:
                result = doctor.collect_tablet_metadata(args.name)
            else:
                result = {
                    'empty_partitions': doctor.check_empty_partitions(),
                    'single_replica_tables': doctor.check_single_replica_tables(),
                    'single_bucket_large_tables': doctor.check_single_bucket_large_tables(),
                    'unpartitioned_large_tables': doctor.check_unpartitioned_large_tables(),
                    'tables_without_index_disk': doctor.check_tables_without_index_disk(),
                    'large_tablets': doctor.check_large_tablets(args.size_gb or 5),
                    'tablets_with_many_versions': doctor.check_tablets_with_many_versions(args.version_threshold),
                    'small_tablets': doctor.check_small_tablets(args.size_mb or 500)
                }
            doctor.save_to_file(result, 'tablet_metadata', args.format)
        elif args.module == 'check_replica':
            if not args.name:
                print("Error: Tablet ID is required for check_replica module")
                return
            doctor.check_and_set_bad_replica(args.name)
        elif args.module == 'session_vars':
            result = doctor.get_modified_session_variables()
            doctor.save_to_file(result, 'modified_session_variables', args.format)
        elif args.module == 'be_config':
            result = doctor.get_modified_be_configs()
            doctor.save_to_file(result, 'modified_be_configs', args.format)
        elif args.module == 'fe_config':
            result = doctor.get_modified_fe_configs()
            doctor.save_to_file(result, 'fe_configs', args.format)
        elif args.module == 'all_configs':
            result = doctor.collect_all_configs()
            doctor.save_to_file(result, 'all_configurations', args.format)
        elif args.module == 'backend_mapping':
            result = doctor.get_backend_host_id_mapping()
            doctor.save_to_file(result, 'backend_host_id_mapping', args.format)
        elif args.module == 'cluster_state':
            result = doctor.collect_cluster_state()
            doctor.save_to_file(result, 'cluster_state', args.format)
        elif args.module == 'performance_diagnostics':
            result = doctor.collect_performance_diagnostics()
            doctor.save_to_file(result, 'performance_diagnostics', args.format)
        elif args.module == 'query_dump':
            if not args.sql_file:
                print("Error: SQL file is required for query_dump module")
                return
            result = doctor.get_query_dump(args.sql_file)
            doctor.save_to_file(result, 'query_dump', args.format)
        elif args.module == 'be_stack':
            if not args.be_ip:
                print("Error: BE IP is required for be_stack module")
                return
            result = doctor.get_be_stack_trace(args.be_ip)
            doctor.save_to_file(result, 'be_stack_trace', args.format)
        elif args.module == 'yesterdays_tables':
            result = doctor.get_yesterdays_tables()
            doctor.save_to_file(result, 'yesterdays_tables', args.format)
        elif args.module == 'remote_diagnostics':
            # Run local manager check first
            manager_log_result = doctor.check_manager_logs()
            print(manager_log_result)

            # Then collect data from all nodes
            result = doctor.collect_data_from_all_nodes(
                ssh_port=args.ssh_port
            )
            doctor.save_to_file(result, 'remote_diagnostics_summary', args.format)

        print(f"Diagnostic data collection complete. Files saved to {args.output}")
    finally:
        if doctor.connection:
            doctor.connection.close()

if __name__ == "__main__":
    main()