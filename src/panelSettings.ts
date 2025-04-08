import { SettingsTreeNodes, SettingsTreeFields, SettingsTreeAction } from "@foxglove/extension";
import { ParameterDetails } from "parameter_types";

import { produce } from "immer";
import * as _ from "lodash-es";



export type Settings = {
  selectedNode: string;
  availableNodeNames: Array<string>;
  selectedParameterName: string;
  selectedNodeAvailableParams: Array<ParameterDetails>;
  inputType: "number" | "slider" | "boolean" | "select" | "text";
};

export type NumericSettings = {
  min: number;
  max: number;
  step: number;
} & Settings;
export type SliderSettings = {
  min: number;
  max: number;
  step: number;
} & Settings;

export type PanelSettings = Settings | NumericSettings | SliderSettings;


export function settingsActionReducer(prevConfig: Settings, action: SettingsTreeAction): Settings {
  return produce(prevConfig, (draft) => {
    if (action.action === "update") {
      const { path, value } = action.payload;
      _.set(draft, path.slice(1), value);
    }
  });
}

export function buildSettingsTree(config: Settings): SettingsTreeNodes {


  // Build the settings tree based on the config
  const dataSourceFields: SettingsTreeFields = {
    selectedNode: {
      label: "Node",
      input: "select",
      value: config.selectedNode,
      options: config.availableNodeNames.map((name) => ({
        label: name,
        value: name,
      })),
      disabled: config.availableNodeNames.length === 0,
    },
    selectedParameterName: {
      label: "Parameter",
      input: "select",
      disabled: config.selectedNodeAvailableParams.length === 0,
      value: config.selectedParameterName,
      options: config.selectedNodeAvailableParams.map((parameter) => ({
        label: parameter.name,
        value: parameter.name,
      })),
    },
    inputType: {
      label: "Input Type",
      input: "select",
      value: config.inputType,
      options: [
        {
          label: "Number",
          value: "number",
        },
        {
          label: "Slider",
          value: "slider",
        },
        {
          label: "Boolean",
          value: "boolean",
        },
        {
          label: "Select",
          value: "select",
        },
        {
          label: "Text",
          value: "text",
        },
      ],
    },
  };

  if (config.inputType === "slider") {
    dataSourceFields["min"] = {
      label: "Min",
      input: "number",
      value: 0,
    };
    dataSourceFields["max"] = {
      label: "Max",
      input: "number",
      value: 100,
    };
    dataSourceFields["step"] = {
      label: "Step",
      input: "number",
      value: 1,
    };
  }

  if (config.inputType === "number") {
    dataSourceFields["min"] = {
      label: "Min",
      input: "number",
      value: 0,
    };
    dataSourceFields["max"] = {
      label: "Max",
      input: "number",
      value: 100,
    };
    dataSourceFields["step"] = {
      label: "Step",
      input: "number",
      value: 1,
    }
  }
  const settings: SettingsTreeNodes = {
    dataSource: {
      label: "Parameter",
      icon: "Settings",
      fields: dataSourceFields,
    },
  };
  return settings;
}
