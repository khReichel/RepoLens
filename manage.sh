#!/bin/bash

# Configuration
CONFIG_FILE="pulseflow_config.yaml"

# 1. Attempt to get the actual bridge gateway IP
DETECTED_GATEWAY=$(docker network inspect bridge --format='{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)

# 2. Fallback logic: If detection fails, use the keyword 'host-gateway'
# (which works on Docker Desktop). If it succeeds, use the IP.
if [ -z "$DETECTED_GATEWAY" ]; then
    export DOCKER_GATEWAY="host-gateway"
else
    export DOCKER_GATEWAY="$DETECTED_GATEWAY"
fi

echo "--- Network Setup: Mapping host.docker.internal to $DOCKER_GATEWAY ---"

# --- Helper Functions ---
# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

case "$1" in
  # 1. Start everything
  up)
    MODE="${2:-prod}"
    case "$MODE" in
      dev)
        echo "build development image"
        docker compose -f docker-compose.dev.yml up -d --build
        ;;
      prod)
        echo "build production image"
        docker compose -f docker-compose.yml up -d --build
        ;;
      *)
        echo "build production image"
        docker compose -f docker-compose.yml up -d --build
        ;;
    esac
    ;;
  # New command to shut down containers
  down)
    echo "Stopping and removing containers..."
    docker compose down
    echo "All services have been shut down."
    ;;

  replace)
    # Validate arguments
    if [ -z "${2:-}" ] || [ -z "${3:-}" ] || [ -z "${4:-}" ]; then
      echo "Usage: ./manage.sh replace <source_dir> <new_basename> <old_basename>"
      exit 1
    fi

    SOURCE_DIR="$2"
    NEW_BASE="$3"
    OLD_BASE="$4"
    SCRIPT_DIR=$(dirname "$0")

    TARGET_DIR="${SCRIPT_DIR}/data"

    CONTAINER="backend"

    # Derived filenames
    NEW_ANALYSIS="${NEW_BASE}.duckdb"
    NEW_CONFIG="${NEW_BASE}_config.duckdb"

    OLD_ANALYSIS="${OLD_BASE}.duckdb"
    OLD_CONFIG="${OLD_BASE}_config.duckdb"

    # Check new files exist
    if [[ ! -f "${SOURCE_DIR}/${NEW_ANALYSIS}" ]] || [[ ! -f "${SOURCE_DIR}/${NEW_CONFIG}" ]]; then
        echo "Error: Source directory must contain:"
        echo "  ${NEW_ANALYSIS}"
        echo "  ${NEW_CONFIG}"
        exit 1
    fi

    # Backup directory
    BACKUP_DIR="${TARGET_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    echo "Backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"

    rollback() {
        echo "Executing rollback..."
        mv -f "${BACKUP_DIR}/${OLD_ANALYSIS}" "${TARGET_DIR}/" 2>/dev/null || true
        mv -f "${BACKUP_DIR}/${OLD_CONFIG}" "${TARGET_DIR}/" 2>/dev/null || true
        docker compose start "$CONTAINER"
        echo "Rollback finished."
    }
    trap rollback ERR

    echo "Stopping backend..."
    docker compose stop "$CONTAINER"

    echo "Backup of the old files..."
    mv "${TARGET_DIR}/${OLD_ANALYSIS}" "$BACKUP_DIR/" 2>/dev/null || true
    mv "${TARGET_DIR}/${OLD_CONFIG}" "$BACKUP_DIR/" 2>/dev/null || true

    echo "Copy new files..."
    cp "${SOURCE_DIR}/${NEW_ANALYSIS}" "${TARGET_DIR}/${OLD_ANALYSIS}"
    cp "${SOURCE_DIR}/${NEW_CONFIG}" "${TARGET_DIR}/${OLD_CONFIG}"

    echo "Starting backend..."
    docker compose start "$CONTAINER"

    echo "Success! Databases have been replaced."
    ;;

  # 3. Run the full import and analysis process
  import)
    if [ -z "$2" ]; then
      echo "Error: Please provide the path to the repository on your host machine."
      echo "Usage: ./manage.sh import /path/to/your/repo"
      exit 1
    fi

    echo "Running full import and analysis process for repository at $2..."

    # Set the environment variable for docker-compose to use.
    export REPO_PATH_HOST=$2

    # Define the command to run inside the container.
    # This includes adding the repo to git's safe directories before running the import.
    CMD="git config --global --add safe.directory /repo && python -m import_export.database_importer"

    # First, import the configuration.
    docker compose run --rm -e PYTHONPATH=/app/src importer sh -c "$CMD config --config-file /app/config/config.yaml"
    # Then, run the analysis.
    docker compose run --rm -e PYTHONPATH=/app/src importer sh -c "$CMD analysis --config-file /app/config/config.yaml"

    # Unset the variable for cleanliness
    unset REPO_PATH_HOST

    echo "Import and analysis complete."
    ;;

  # Debug command to print Python's sys.path
  debug-path)
    echo "Debugging Python path in the 'importer' container..."
    docker compose run --rm -e PYTHONPATH=/app/src importer python -c "import sys; import os; print('--- Python Search Path (sys.path) ---'); [print(p) for p in sys.path]; print('\n--- Contents of /app/src ---'); os.system('ls -l /app/src')"
    ;;

  update)
      echo “Rebuild images and start containers...”
      # --build forces the images to be rebuilt
      # --remove-orphans deletes containers that are no longer in docker-compose.yml
      docker compose up -d --build --remove-orphans
      echo "Update completed."
      ;;

  logs)
      echo “Logs are being written to the ./logs/ folder...”
      # ‘nohup’ allows the command to continue running in the background
      # ‘split’ ensures that the files do not become infinitely large
      docker compose logs -f -t > ./logs/combined_$(date +%Y%m%d).log 2>&1 &
      echo "Log-Streaming im Hintergrund gestartet."
      ;;

  pull-latest)
      echo "Load latest images from github ..."
      docker compose pull
      docker compose up -d
      echo "Update completed."
      ;;


  *)
      echo "Commands:"
      echo "  ./manage.sh up                                   - Build and start all services"
      echo "  ./manage.sh down                                 - Stop and remove all services"
      echo "  ./manage.sh import <path>                        - Run the full import and analysis for a local repository"
      echo "  ./manage.sh replace <src> <new_base> <old_base>  - Safely replace database files"
      echo "       <src>       = Directory with new files"
      echo "       <new_base>  = Base name of the new files (e.g., pulseflow)"
      echo "       <old_base>  = Base name of the previous files"
      echo "  ./manage.sh logs                                 - Stream container logs to a file"
      echo "  ./manage.sh pull-latest                          - Pull latest images from registry and restart"
      echo "  ./manage.sh update                               - Rebuild images and restart containers"
      echo "  ./manage.sh debug-path                           - Print Python's search path inside the importer container"
      exit 1
      ;;

esac
