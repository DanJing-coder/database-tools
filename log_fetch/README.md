# log_fetch - StarRocks Log Information Retrieval Tool

`log_fetch` is a set of scripts designed to retrieve log information from the specified time period for each Frontend (FE) and Backend (BE) node of StarRocks using SSH rotation.

## Usage

1. **Clone the Repository**

   ```bash
   git clone https://github.com/lwlei/log_fetch.git
   ```
   
3. **Navigate to the Project Directory**

   ```bash
   cd log_fetch
   ```
   
5. **View the Help Information**

   For all_log_fetch.sh, which iterates through all specified nodes:
   
   ```bash
   ./all_log_fetch.sh -h
   ```
   
   <img width="1072" alt="image" src="https://github.com/lwlei/log_fetch/assets/49778699/c222cddd-7b91-4d08-be49-f1d3eb213223">
   
   For log_fetch.sh, which collects logs on individual nodes:
   
   ```bash
   ./log_fetch.sh -h
   ```
    <img width="971" alt="image" src="https://github.com/lwlei/log_fetch/assets/49778699/c276d12e-256d-4035-adb6-1e85062f834d">
   
   
7. **Run the Scripts**
   
   Use all_log_fetch.sh to initiate the process, which will distribute log_fetch.sh to each node and collect logs:
   
   ```bash
   ./all_log_fetch.sh [options]
   ```
   
   The options should be provided according to the help information displayed by the -h flag.
   
## Important Notes

- Ensure that you have SSH keys set up correctly, and that the private key is available in the environment from which you run the script.
- The script may require specific permissions to access the log files on the StarRocks nodes.
- The script may generate a large amount of log data; ensure sufficient storage space of /tmp is available.

## Contributing and Feedback

Feel free to submit pull requests to improve the scripts or raise issues on GitHub for bugs or feature requests.
