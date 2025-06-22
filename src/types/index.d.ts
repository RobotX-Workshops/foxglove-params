declare module "parameter_types" {
  export const paramTypeList: string[] = [
    "boolean",
    "integer",
    "double",
    "string",
    "byte_array",
    "boolean_array",
    "integer_array",
    "double_array",
    "string_array",
  ];

  export type ParameterDetails = {
    name: string;
    value: ParameterValueDetails;
  };

  export type ParameterValueDetails =
    | number
    | boolean
    | string
    | number[]
    | boolean[]
    | string[];
}

type PanelState = {
  settings: PanelSettings;
};
