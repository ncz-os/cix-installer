from libnoe import *
import numpy as np
import struct
import time
from typing import Union

def get_data_info(d_type : noe_data_type_t) -> tuple:
    if d_type == noe_data_type_t.NOE_DATA_TYPE_S8:
        type_info = (np.int8, -128, 127,np.int8)
    elif d_type == noe_data_type_t.NOE_DATA_TYPE_U8:
        type_info = (np.uint8, 0, 255,np.uint8)
    elif d_type == noe_data_type_t.NOE_DATA_TYPE_S16:
        type_info = (np.int16, -32768, 32767,np.int16)
    elif d_type == noe_data_type_t.NOE_DATA_TYPE_U16:
        type_info = (np.uint16, 0, 65535,np.uint16)
    elif d_type == noe_data_type_t.NOE_DATA_TYPE_S32:
        type_info = (np.int32, -2147483648, 2147483647,np.int32)
    elif d_type == noe_data_type_t.NOE_DATA_TYPE_U32:
        type_info = (np.uint32, 0, 4294967295,np.uint32)
    elif d_type == noe_data_type_t.NOE_DATA_TYPE_F16:
        type_info = (np.float16, 0, 0,np.float16)
    else:
        raise NotImplementedError(f"Not Implement d_type {d_type}")
    return type_info

class EngineInfer:
    def __init__(self, model_path):
        self.model_path = model_path
        self.job_cfg = noe_create_job_cfg_t()

        self.npu = NPU()

        self.input_type = []
        self.input_dtype_min = []
        self.input_dtype_max = []
        self.intype = []
        self.in_tensor_desc = []

        self.output_type = []
        self.output_dtype_min = []
        self.output_dtype_max = []
        self.outtype = []
        self.out_tensor_desc = []

        self._init_context()
        self._load_graph()
        self._setup_tensors(NOE_TENSOR_TYPE_INPUT)
        self._setup_tensors(NOE_TENSOR_TYPE_OUTPUT)
        self._create_job()

    def _init_context(self):
        if self.npu.noe_init_context() != 0:
            raise RuntimeError("npu: noe_init_context fail")

    def _load_graph(self):
        ret,graph_id = self.npu.noe_load_graph(self.model_path)
        if ret != 0:
            raise RuntimeError("npu: noe_load_graph failed")
        self.graph_id = graph_id

    def _get_tensor_count(self, tensor_type : int) -> int:
        ret,count = self.npu.noe_get_tensor_count(self.graph_id, tensor_type)
        if ret != 0:
            raise RuntimeError(f"npu: noe_get_output_tensor failed for type {tensor_type}")
        return count

    def _setup_tensors(self, tensor_type : int):
        tensor_count = self._get_tensor_count(tensor_type)
        tensor_list = self.in_tensor_desc if tensor_type == NOE_TENSOR_TYPE_INPUT else self.out_tensor_desc
        tensor_properties = (self.input_type, self.input_dtype_min, self.input_dtype_max, self.intype) if tensor_type == NOE_TENSOR_TYPE_INPUT else (self.output_type, self.output_dtype_min, self.output_dtype_max, self.outtype)

        for idx in range(tensor_count):
            desc = self.npu.noe_get_tensor_descriptor(self.graph_id, tensor_type, idx)
            tensor_list.append(desc)
            data_type_info = get_data_info(desc.data_type)
            for prop, value in zip(tensor_properties, data_type_info):
                prop.append(value)

    def _create_job(self):
        ret,job_id = self.npu.noe_create_job(self.graph_id, self.job_cfg)
        if ret != 0:
            raise RuntimeError("npu: noe_create_job failed")
        self.job_id = job_id

    def forward(self, input_datas : Union[list, np.ndarray]) -> list:
        if not isinstance(input_datas, list):
            input_datas = [input_datas]
        assert type(input_datas) == list, "input datas must a list."
        assert len(input_datas) == len(self.in_tensor_desc), f"len of input_datas:{len(input_datas)} does not match expected: {len(self.in_tensor_desc)}."

        job_id = self.job_id
        self.output = []

        for i, input_data in enumerate(input_datas):
            input_data = np.round(input_data.astype(float) * self.in_tensor_desc[i].scale - self.in_tensor_desc[i].zero_point)
            input_data = np.clip(input_data, self.input_dtype_min[i], self.input_dtype_max[i]).astype(self.input_type[i])
            self.npu.noe_load_tensor(job_id, i, input_data.tobytes())

        self.npu.noe_job_infer_sync(job_id, -1)

        for j in range(len(self.out_tensor_desc)):
            retmap,data = self.npu.noe_get_tensor(job_id, NOE_TENSOR_TYPE_OUTPUT, j)
            if retmap != 0:
                raise RuntimeError("npu: noe_get_tensor failed")
            output_data = np.frombuffer(data, dtype=self.output_type[j])
            self.output.append((output_data.astype(np.float32) + self.out_tensor_desc[j].zero_point) / self.out_tensor_desc[j].scale)

        return self.output

    def clean(self):
        self.npu.noe_clean_job(self.job_id)
        self.npu.noe_unload_graph(self.graph_id)
        self.npu.noe_deinit_context()
