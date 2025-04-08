declare module "parameter_types" {
    export let paramTypeList: string[] = ["boolean", "integer", "double", "string", "byte_array", "boolean_array", "integer_array", "double_array", "string_array"];

    export type ParameterDetails = {
        name: string;
        value: ParameterValueDetails;
    }

    export type ParameterValueDetails = {
        [key: string]: any;
        type: number;
        bool_value: boolean;
        integer_value: number;
        double_value: number;
        string_value: string;
        byte_array_value: number[];
        bool_array_value: boolean[];
        integer_array_value: number[];
        double_array_value: number[];
        string_array_value: string[];
    }


}