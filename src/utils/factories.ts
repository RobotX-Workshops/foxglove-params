import { ParameterValueDetails } from "parameter_types";

export function mergeParams(
  originalParams: ParameterValueDetails,
  newParams: Partial<ParameterValueDetails>,
): ParameterValueDetails {
  return {
    ...originalParams,
    ...newParams,
  };
}

export function createParams(
  params: Partial<ParameterValueDetails>,
): ParameterValueDetails {
  // Default values for all properties
  const defaultParams: ParameterValueDetails = {
    type: 0,
    bool_value: false,
    integer_value: 0,
    double_value: 0,
    string_value: "",
    byte_array_value: [],
    bool_array_value: [],
    integer_array_value: [],
    double_array_value: [],
    string_array_value: [],
  };

  return {
    ...defaultParams,
    ...params,
  };
}
