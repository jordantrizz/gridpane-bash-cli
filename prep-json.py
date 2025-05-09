import json
import sys
import jsonlines
if len(sys.argv) != 3:
    print("Usage: python prep-json.py <input_file> <output_file>")
    sys.exit(1)

# File containing multiple JSON objects
input_file = sys.argv[1]
# Output file to save the combined JSON array
output_file = sys.argv[2]


json_objects = []
with jsonlines.open(input_file) as reader:
    for obj in reader:
        json_objects.append(obj)
# Write the list of JSON objects to a single JSON file
with open(output_file, 'w') as f:
    json.dump(json_objects, f, indent=4)
print(f"Combined JSON objects from {input_file} into {output_file}")