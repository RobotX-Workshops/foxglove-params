import {
  SettingsTreeNodes,
  SettingsTreeFields,
  SettingsTreeAction,
} from "@foxglove/extension";
import { produce } from "immer";
import * as _ from "lodash-es";
import { ParameterDetails } from "parameter_types";

export type Settings = {
  selectedNode: string;
  availableNodeNames: Array<string>;
  selectedParameterName: string;
  allData: Record<string, ParameterDetails[]>;
  selectedNodeAvailableParams: Array<ParameterDetails>;
  inputType: "number" | "slider" | "boolean" | "select" | "text";
};

export type NumericSettings = {
  min: number;
  max: number;
  step: number;
} & Settings;

export type PanelSettings = Settings | NumericSettings;

export function settingsActionReducer(
  prevConfig: Settings,
  action: SettingsTreeAction,
): Settings {
  return produce(prevConfig, (draft) => {
    if (action.action === "update") {
      const { path, value } = action.payload;
      _.set(draft, path.slice(1), value);
    }
  });
}

export function buildSettingsTree(config: PanelSettings): SettingsTreeNodes {
  console.log("Building settings tree with config:", config);
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
    // eslint-disable-next-line no-var
    var numSettings = config as NumericSettings;
    dataSourceFields["min"] = {
      label: "Min",
      input: "number",
      value: numSettings.min,
    };
    dataSourceFields["max"] = {
      label: "Max",
      input: "number",
      value: numSettings.max,
    };
    dataSourceFields["step"] = {
      label: "Step",
      input: "number",
      value: numSettings.step,
    };
  }

  if (config.inputType === "number") {
    // eslint-disable-next-line no-var
    var numSettings = config as NumericSettings;
    dataSourceFields["min"] = {
      label: "Min",
      input: "number",
      value: numSettings.min,
    };
    dataSourceFields["max"] = {
      label: "Max",
      input: "number",
      value: numSettings.max,
    };
    dataSourceFields["step"] = {
      label: "Step",
      input: "number",
      value: numSettings.step,
    };
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
