declare module "parameter_types" {

    export type ParameterNameValue = {
        name: string;
        value: ParameterValueDetails;
    }

    export type ParameterValueDetails = {
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

        export type SetSrvParam = { 
        name?: string;
        value?: {
            type: number;
            bool_value?: boolean;
            integer_value?: number;
            double_value?: number;
            string_value?: string;
            byte_array_value?: number[];
            bool_array_value?: boolean[];
            integer_array_value?: number[];
            double_array_value?: number[];
            string_array_value?: string[];
        }
    }

}