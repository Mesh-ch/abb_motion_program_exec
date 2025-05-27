# Copyright 2022 Wason Technology LLC, Rensselaer Polytechnic Institute
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from .command_base import CommandBase
from dataclasses import dataclass
from .rapid_types import *
import io
from . import util

@dataclass
class MoveAbsJCommand(CommandBase):
    command_opcode = 1

    to_joint_pos: jointtarget
    speed: speeddata
    zone: zonedata

    def write_params(self, f: io.IOBase):
        to_joint_pos_b = util.jointtarget_to_bin(self.to_joint_pos)
        speed_b = util.speeddata_to_bin(self.speed)
        zone_b = util.zonedata_to_bin(self.zone)
        f.write(to_joint_pos_b)
        f.write(speed_b)
        f.write(zone_b)

    def to_rapid(self, sync_move = False, cmd_num = 0, **kwargs):
        to_joint_pos_str = self.to_joint_pos.to_rapid()
        speed_str = self.speed.to_rapid()
        zone_str = self.zone.to_rapid()
        sync_id = "" if not sync_move else rf"\\ID:={cmd_num},"
        return rf"MoveAbsJ {to_joint_pos_str}, {sync_id}{speed_str}, {zone_str}, motion_program_tool\\Wobj:=motion_program_wobj;"

    _append_method_doc = ""

@dataclass
class MoveJCommand(CommandBase):
    command_opcode = 2

    to_point: robtarget
    speed: speeddata
    zone: zonedata

    def write_params(self, f: io.IOBase):
        to_point_b = util.robtarget_to_bin(self.to_point)
        speed_b = util.speeddata_to_bin(self.speed)
        zone_b = util.zonedata_to_bin(self.zone)
        f.write(to_point_b)
        f.write(speed_b)
        f.write(zone_b)

    def to_rapid(self, sync_move = False, cmd_num = 0, **kwargs):
        to_point_str = self.to_point.to_rapid()
        speed_str = self.speed.to_rapid()
        zone_str = self.zone.to_rapid()

        sync_id = "" if not sync_move else rf"\\ID:={cmd_num},"
        return rf"MoveJ {to_point_str}, {sync_id}{speed_str}, {zone_str}, motion_program_tool\\Wobj:=motion_program_wobj;"

    _append_method_doc = ""

@dataclass
class MoveLCommand(CommandBase):
    command_opcode = 3

    to_point: robtarget
    speed: speeddata
    zone: zonedata

    def write_params(self, f: io.IOBase):
        to_point_b = util.robtarget_to_bin(self.to_point)
        speed_b = util.speeddata_to_bin(self.speed)
        zone_b = util.zonedata_to_bin(self.zone)

        f.write(to_point_b)
        f.write(speed_b)
        f.write(zone_b)

    def to_rapid(self, sync_move = False, cmd_num = 0, **kwargs):
        to_point_str = self.to_point.to_rapid()
        speed_str = self.speed.to_rapid()
        zone_str = self.zone.to_rapid()

        sync_id = "" if not sync_move else rf"\\ID:={cmd_num},"
        return rf"MoveL {to_point_str}, {sync_id}{speed_str}, {zone_str}, motion_program_tool\\Wobj:=motion_program_wobj;"

    _append_method_doc = ""

@dataclass
class MoveCCommand(CommandBase):
    command_opcode = 4

    cir_point: robtarget
    to_point: robtarget
    speed: speeddata
    zone: zonedata

    def write_params(self, f: io.IOBase):
        cir_point_b = util.robtarget_to_bin(self.cir_point)
        to_point_b = util.robtarget_to_bin(self.to_point)
        speed_b = util.speeddata_to_bin(self.speed)
        zone_b = util.zonedata_to_bin(self.zone)

        f.write(cir_point_b)
        f.write(to_point_b)
        f.write(speed_b)
        f.write(zone_b)

    def to_rapid(self, sync_move = False, cmd_num = 0, **kwargs):
        cir_point_str = self.cir_point.to_rapid()
        to_point_str = self.to_point.to_rapid()
        speed_str = self.speed.to_rapid()
        zone_str = self.zone.to_rapid()
        sync_id = "" if not sync_move else rf"\\ID:={cmd_num},"
        return rf"MoveC {cir_point_str}, {sync_id}{to_point_str}, {speed_str}, {zone_str}, motion_program_tool\\Wobj:=motion_program_wobj;"

    _append_method_doc = ""

@dataclass
class WaitTimeCommand(CommandBase):
    command_opcode=5

    t: float

    def write_params(self, f: io.IOBase):
        f.write(util.num_to_bin(self.t))

    def to_rapid(self, **kwargs):
        return f"WaitTime {self.t};"

    _append_method_doc = ""

@dataclass
class CirPathModeCommand(CommandBase):
    command_opcode = 6

    switch: CirPathModeSwitch

    def write_params(self, f: io.IOBase):
        val = self.switch.value
        if not (val >=1 and val <= 6):
            raise Exception("Invalid CirPathMode switch")
        f.write(util.num_to_bin(val))

    def to_rapid(self, **kwargs):
        if  self.switch == 1:
            return r"CirPathMode\PathFrame;"
        if self.switch == 2:
            return r"CirPathMode\ObjectFrame;"
        if self.switch == 3:
            return r"CirPathMode\CirPointOri;"
        if self.switch == 4:
            return r"CirPathMode\Wrist45;"
        if self.switch == 5:
            return r"CirPathMode\Wrist46;"
        if self.switch == 6:
            return r"CirPathMode\Wrist56;"
        raise Exception("Invalid CirPathMode switch")

    _append_method_doc = ""

@dataclass
class SyncMoveOnCommand(CommandBase):
    command_opcode = 7

    def write_params(self, f: io.IOBase):
        pass

    def to_rapid(self, **kwargs):
        return "SyncMoveOn motion_program_sync1,task_list;"

    _append_method_doc = ""

class SyncMoveOffCommand(CommandBase):
    command_opcode = 8

    def write_params(self, f: io.IOBase):
        pass

    def to_rapid(self, **kwargs):
        return "SyncMoveOff motion_program_sync2;"

    _append_method_doc = ""

@dataclass
class SetDOCommand(CommandBase):
    command_opcode = 9

    signal_name: str
    signal_value: bool

    def write_params(self, f: io.IOBase):
        # pass
        signal_name_b = util.str_to_bin(self.signal_name)
        if self.signal_value:
            signal_bool_to_int = 1
        else:
            signal_bool_to_int = 0
        signal_value_b = util.num_to_bin(signal_bool_to_int)

        f.write(signal_name_b)
        f.write(signal_value_b)

    def to_rapid(self, **kwargs):
        return f"SetDO '{self.signal_name}' {self.signal_value};"

    _append_method_doc = ""
    
@dataclass
class MoveLRelTool(CommandBase):
    command_opcode = 10
    speed: speeddata = v100
    distance: float = -100

    def write_params(self, f: io.IOBase):
        speed_b = util.speeddata_to_bin(self.speed)
        distance_b = util.num_to_bin(self.distance)
        
        f.write(speed_b)
        f.write(distance_b)

    def to_rapid(self, **kwargs):
        return "MoveL RelTool "

    _append_method_doc = ""

@dataclass
class SetGOCommand(CommandBase):
    command_opcode = 11

    signal_name: str
    signal_value: int 

    def write_params(self, f: io.IOBase):
        # pass
        signal_name_b = util.str_to_bin(self.signal_name)
        signal_value_b = util.num_to_bin(self.signal_value)

        f.write(signal_name_b)
        f.write(signal_value_b)

    def to_rapid(self, **kwargs):
        return f"SetGO '{self.signal_name}' {self.signal_value};"

    _append_method_doc = ""
    
@dataclass
class WaitDICommand(CommandBase):
    command_opcode = 12

    signal_name: str
    signal_value: bool

    def write_params(self, f: io.IOBase):
        # pass
        signal_name_b = util.str_to_bin(self.signal_name)
        if self.signal_value:
            signal_bool_to_int = 1
        else:
            signal_bool_to_int = 0
        signal_value_b = util.num_to_bin(signal_bool_to_int)

        f.write(signal_name_b)
        f.write(signal_value_b)

    def to_rapid(self, **kwargs):
        return f"WaitDI '{self.signal_name}' {self.signal_value};"

    _append_method_doc = ""
    
@dataclass
class WaitGICommand(CommandBase):
    command_opcode = 13

    signal_name: str
    signal_value: int

    def write_params(self, f: io.IOBase):
        # pass
        signal_name_b = util.str_to_bin(self.signal_name)
        signal_value_b = util.num_to_bin(self.signal_value)

        f.write(signal_name_b)
        f.write(signal_value_b)

    def to_rapid(self, **kwargs):
        return f"WaitGI '{self.signal_name}' {self.signal_value};"

    _append_method_doc = ""
    
@dataclass
class RunCBCCommand(CommandBase):
    command_opcode = 14

    def write_params(self, f: io.IOBase):
        pass
    
    def to_rapid(self, **kwargs):
        return "CyclicBrakeCheck;"

    _append_method_doc = ""
    
@dataclass
class RunTieCommand(CommandBase):
    command_opcode = 15

    to_point: robtarget
    speed: speeddata
    zone: zonedata
    approach_offset: float
    no_tie: bool

    def write_params(self, f: io.IOBase):
        to_point_b = util.robtarget_to_bin(self.to_point)
        speed_b = util.speeddata_to_bin(self.speed)
        zone_b = util.zonedata_to_bin(self.zone)
        approach_offset_b = util.num_to_bin(self.approach_offset)
        no_tie_b = util.num_to_bin(1 if self.no_tie else 0)

        f.write(to_point_b)
        f.write(speed_b)
        f.write(zone_b)
        f.write(approach_offset_b)
        f.write(no_tie_b)

    def to_rapid(self, sync_move = False, cmd_num = 0, **kwargs):
        to_point_str = self.to_point.to_rapid()
        speed_str = self.speed.to_rapid()
        zone_str = self.zone.to_rapid()
        approach_offset_str = self.approach_offset

        sync_id = "" if not sync_move else rf"\\ID:={cmd_num},"
        return rf"MoveL {to_point_str}, {sync_id}{speed_str}, {zone_str}, motion_program_tool\\Wobj:=motion_program_wobj;"

    _append_method_doc = ""