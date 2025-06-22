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

type PanelState = {
  settings: PanelSettings;
};

export type Settings = {
  params: Map<string, Array<ParameterDetails>>;
  selectedNode: string;
  selectedParameterName: string;
  inputType: "number" | "slider" | "boolean" | "select" | "text";
};

export type NumericSettings = {
  min: number;
  max: number;
  step: number;
} & Settings;

export type SelectSettings = {
  selectOptions: Array<string>;
  selectOptionsAmount: number;
} & Settings;

export type PanelSettings = Settings | NumericSettings | SelectSettings;
