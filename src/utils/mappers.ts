import { ParameterValueDetails } from "parameter_types";



  /**
   * converts string representation of a boolean to a boolean
   * @param stringValue "true" or "false"
   * @returns true or false
   */
export  const stringToBoolean = (stringValue: string) => {
    switch(stringValue?.toLowerCase()?.trim()){
        case "true": return true;
        case "false": return false;
        default: throw new Error(`Invalid boolean string: ${stringValue}`);
    }
  }

export const paramTypeIds = {
    boolean: 1,
    integer: 2,
    double: 3,
    string: 4,
    byte_array: 5,
    boolean_array: 6,
    integer_array: 7,
    double_array: 8,
    string_array: 9
};

// Reverse mapping in one line
export const idsToParamType = Object.fromEntries(
    Object.entries(paramTypeIds).map(([type, id]) => [id, type])
);

export function mapParamValue(param: ParameterValueDetails, val: string): ParameterValueDetails {
    param = {...param}; // Create a shallow copy of the parameter object
    switch (idsToParamType[param.type]) {
        case "boolean": // 1
            param.bool_value = stringToBoolean(val);
            break;
        case "integer": // 2
            param!.integer_value = +val;
            break;
        case "double": // 3
            param.double_value = +val;
            break;
        case "string": // 4
            param.string_value = val;
            break;
        // TODO: Implement format for byte arrays
        case "byte_array": // 5
            // param.byte_array_value = val as unknown as number[];
            break;
        case "boolean_array": // 6
            param.bool_array_value = val
                .replace(" ", "")
                .replace("[", "")
                .replace("]", "")
                .split(",")
                .map((element) => {
                    if (element == "true") return true;
                    return false;
                });
            break;
        case "integer_array": // 7
            param.integer_array_value = val
                .replace(" ", "")
                .replace("[", "")
                .replace("]", "")
                .split(",")
                .map(Number);
            break;
        case "double_array": // 8
            param.double_array_value = val
                .replace(" ", "")
                .replace("[", "")
                .replace("]", "")
                .split(",")
                .map(Number);
            break;
        case "string_array": // 9
            val.replace(" ", "");
            if (val.charAt(0) == "[" && val.charAt(val.length - 1) == "]")          
                val = val.substring(1, val.length - 1);
            param.string_array_value = val.split(",");
            break;
        default: throw new Error(`Invalid parameter type: ${param.type}`);
    }
    return param;
}