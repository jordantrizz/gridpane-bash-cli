#!/bin/env bash
# This script is used to prepare JSON data for the GridPane API
# Setup venv environment
# check if python3-venv is installed
if ! command -v python3 &> /dev/null
then
    echo "python3 could not be found"
    exit
fi
if ! command -v pip3 &> /dev/null
then
    echo "pip3 could not be found"
    exit
fi

if [[ ! -d ".venv" ]]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
    if [[ $? -ne 0 ]]; then
        echo "Failed to create virtual environment"
        exit 1
    fi
    source .venv/bin/activate
    pip install -r requirements.txt
else
    echo "Activating virtual environment..."
    source .venv/bin/activate
    python3 prep-json.py $@
fi



