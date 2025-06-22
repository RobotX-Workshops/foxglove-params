import {
  SettingsTreeNodes,
  SettingsTreeFields,
  SettingsTreeAction,
} from "@foxglove/extension";
import { produce } from "immer";
import * as _ from "lodash-es";
import { ParameterDetails } from "parameter_types";

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
  const selectedNodeParams = config.params.get(config.selectedNode) ?? [];
  const inputOptions = [];

  if (selectedNodeParams.find((param) => typeof param.value === "boolean")) {
    inputOptions.push({
      label: "Boolean",
      value: "boolean",
    });
  }
  if (selectedNodeParams.find((param) => typeof param.value === "string")) {
    inputOptions.push({
      label: "Text",
      value: "text",
    });
    inputOptions.push({
      label: "Select",
      value: "select",
    });
  }
  if (selectedNodeParams.find((param) => typeof param.value === "number")) {
    inputOptions.push({
      label: "Number",
      value: "number",
    });
    inputOptions.push({
      label: "Slider",
      value: "slider",
    });
  }
  if (
    selectedNodeParams.find(
      (param) =>
        Array.isArray(param.value) && typeof param.value[0] === "number",
    )
  ) {
    inputOptions.push({
      label: "Number Array",
      value: "number_array",
    });
  }
  if (
    selectedNodeParams.find(
      (param) =>
        Array.isArray(param.value) && typeof param.value[0] === "boolean",
    )
  ) {
    inputOptions.push({
      label: "Boolean Array",
      value: "boolean_array",
    });
  }
  if (
    selectedNodeParams.find(
      (param) =>
        Array.isArray(param.value) && typeof param.value[0] === "string",
    )
  ) {
    inputOptions.push({
      label: "String Array",
      value: "string_array",
    });
  }

  const dataSourceFields: SettingsTreeFields = {
    selectedNode: {
      label: "Node",
      input: "select",
      value: config.selectedNode,
      options: Array.from(config.params.keys()).map((nodeName) => ({
        label: nodeName,
        value: nodeName,
      })),
    },
    selectedParameterName: {
      label: "Parameter",
      input: "select",
      disabled: selectedNodeParams.length === 0,
      value: config.selectedParameterName,
      options: selectedNodeParams.map((param: ParameterDetails) => ({
        label: param.name,
        value: param.name,
      })),
    },
    inputType: {
      label: "Input Type",
      input: "select",
      value: config.inputType,
      options: inputOptions,
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

  if (config.inputType === "select") {
    // eslint-disable-next-line no-var
    var selectSettings = config as SelectSettings;
    dataSourceFields["selectOptionsAmount"] = {
      label: "Select Options Amount",
      input: "number",
      value: selectSettings.selectOptions.length,
    };

    for (let i = 0; i < selectSettings.selectOptions.length; i++) {
      dataSourceFields[`selectOption${i}`] = {
        label: `Select Option ${i + 1}`,
        input: "string",
        value: selectSettings.selectOptions[i],
        placeholder: `Option ${i + 1}`,
      };
    }
  }
  return settings;
}
