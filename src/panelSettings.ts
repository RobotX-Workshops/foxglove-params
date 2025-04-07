import { SettingsTreeNodes, SettingsTreeFields, SettingsTreeAction } from "@foxglove/extension";
import { ParameterNameValue } from "parameter_types";

import { produce } from "immer";
import * as _ from "lodash-es";

export type Config = {
  selectedNode: string;
  availableNodeNames: Array<string>;
  selectedParameter: string;
  selectedNodeAvailableParams: Array<ParameterNameValue>;
  inputType: "number" | "slider" | "boolean" | "select" | "text";
};

export function settingsActionReducer(prevConfig: Config, action: SettingsTreeAction): Config {
  return produce(prevConfig, (draft) => {
    if (action.action === "update") {
      const { path, value } = action.payload;
      _.set(draft, path.slice(1), value);
    }
  });
}

export function buildSettingsTree(config: Config, ): SettingsTreeNodes {
  const dataSourceFields: SettingsTreeFields = {
    node: {
      label: "Node",
      input: "select",
      value: config.selectedNode,
      options: config.availableNodeNames.map((name) => ({
        label: name,
        value: name,
      })),
      disabled: config.availableNodeNames.length === 0,
    },
    parameter: {
      label: "Parameter",
      input: "select",
      disabled: config.selectedNodeAvailableParams.length === 0,
      value: config.selectedParameter,
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

  const settings: SettingsTreeNodes = {
    dataSource: {
      label: "Parameter",
      icon: "Settings",
      fields: dataSourceFields,
    },
  };

  return settings;
}
