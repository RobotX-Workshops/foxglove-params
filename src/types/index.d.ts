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

export type PanelState = {
  settings: PanelSettings;
};

export type Settings = {
  selectedNode: string;
  selectedParameterName: string;
  inputType: "number" | "slider" | "boolean" | "select" | "text";
};

export type ParamsByNode = Map<string, Array<ParameterDetails>>;

export type NumericSettings = {
  min: number;
  max: number;
  step: number;
} & Settings;

export type SelectSettings = {
  selectOptions?: Array<string>;
  selectOptionsAmount?: number;
} & Settings;

export type PanelSettings = Settings | NumericSettings | SelectSettings;
