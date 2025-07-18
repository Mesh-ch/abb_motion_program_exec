MODULE motion_program_exec
    PERS num current_target_idx;
    PERS num skipped_target_counter;
    CONST num max_targets:=256;
    PERS num skipped_targets{max_targets};
    VAR clock production_clock;
    VAR num production_time;
    PERS num x_offset;
    PERS num y_offset;
    PERS num z_offset;
    PERS num matching_accuracy;
    CONST num MOTION_PROGRAM_DRIVER_MODE:=0;

    CONST num MOTION_PROGRAM_CMD_NOOP:=0;
    CONST num MOTION_PROGRAM_CMD_MOVEABSJ:=1;
    CONST num MOTION_PROGRAM_CMD_MOVEJ:=2;
    CONST num MOTION_PROGRAM_CMD_MOVEL:=3;
    CONST num MOTION_PROGRAM_CMD_MOVEC:=4;
    CONST num MOTION_PROGRAM_CMD_WAIT:=5;
    CONST num MOTION_PROGRAM_CMD_CIRMODE:=6;
    CONST num MOTION_PROGRAM_CMD_SYNCMOVEON:=7;
    CONST num MOTION_PROGRAM_CMD_SYNCMOVEOFF:=8;
    CONST num MOTION_PROGRAM_CMD_SETDO:=9;
    !digital output
    CONST num MOTION_PROGRAM_CMD_MOVELRELTOOL:=10;
    CONST num MOTION_PROGRAM_CMD_SETGO:=11;
    !set group output
    CONST num MOTION_PROGRAM_CMD_WAITDI:=12;
    !wait for digital input
    CONST num MOTION_PROGRAM_CMD_WAITGI:=13;
    !wait for group input
    CONST num MOTION_PROGRAM_CMD_CBC:=14;
    !Run cyclic brake check
    CONST num MOTION_PROGRAM_CMD_TIE:=15;
    !Run tying cycle


    LOCAL VAR iodev motion_program_io_device;
    LOCAL VAR rawbytes motion_program_bytes;
    LOCAL VAR num motion_program_bytes_offset;

    TASK PERS tooldata motion_program_tool:=[TRUE,[[64.4664,0.233697,727.505],[0.707,0,0,-0.707]],[25,[0,0,300],[1,0,0,0],0,0,0]];
    TASK PERS wobjdata motion_program_wobj:=[FALSE,TRUE,"ROB_1",[[0,0,0],[1,0,0,0]],[[0,0,0],[1,0,0,0]]];
    TASK PERS loaddata motion_program_gripload:=[0.001,[0,0,0.001],[1,0,0,0],0,0,0];

    LOCAL VAR rmqslot logger_rmq;

    LOCAL VAR intnum motion_trigg_intno;
    LOCAL VAR triggdata motion_trigg_data;
    LOCAL VAR num motion_cmd_num_history{128};
    LOCAL VAR num motion_current_cmd_ind;
    LOCAL VAR num motion_max_cmd_ind;

    VAR errnum ERR_INVALID_MP_VERSION:=-1;
    VAR errnum ERR_INVALID_MP_FILE:=-1;
    VAR errnum ERR_MISSED_PREEMPT:=-1;
    VAR errnum ERR_INVALID_OPCODE:=-1;

    LOCAL PERS tasks task_list{2}:=[["T_ROB1"],["T_ROB2"]];

    VAR syncident motion_program_sync1;
    VAR syncident motion_program_sync2;

    LOCAL VAR num task_ind;
    LOCAL VAR string motion_program_filename;

    VAR bool motion_program_have_egm:=TRUE;

    LOCAL VAR num motion_program_driver_seqno;

    LOCAL VAR intnum motion_program_driver_abort_into;

    PROC motion_program_main()
        IF MOTION_PROGRAM_DRIVER_MODE=0 THEN
            motion_program_init;
            run_motion_program_file(motion_program_filename);
            motion_program_fini;
        ELSE
            motion_program_main_driver_mode;
        ENDIF
    ENDPROC

    PROC motion_program_init()
        VAR string taskname;
        BookErrNo ERR_INVALID_MP_VERSION;
        BookErrNo ERR_INVALID_MP_FILE;
        BookErrNo ERR_MISSED_PREEMPT;
        BookErrNo ERR_INVALID_OPCODE;
        taskname:=GetTaskName();
        IF taskname="T_ROB1" THEN
            motion_program_filename:="motion_program.bin";
            task_ind:=1;
        ELSEIF taskname="T_ROB2" THEN
            motion_program_filename:="motion_program2.bin";
            task_ind:=2;
        ENDIF
        IF task_ind=1 THEN
            SetAO motion_program_preempt,0;
            SetAO motion_program_preempt_current,0;
            SetAO motion_program_preempt_cmd_num,-1;
            SetAO motion_program_current_cmd_num,-1;
            SetAO motion_program_queued_cmd_num,-1;
            SetAO motion_program_seqno,-1;
        ENDIF
        motion_program_state{task_ind}.current_cmd_num:=-1;
        motion_program_state{task_ind}.queued_cmd_num:=-1;
        motion_program_state{task_ind}.preempt_current:=0;
        motion_current_cmd_ind:=0;
        motion_max_cmd_ind:=0;
        IDelete motion_trigg_intno;
        CONNECT motion_trigg_intno WITH motion_trigg_trap;
        TriggInt motion_trigg_data,0.001,\Start,motion_trigg_intno;
        RMQFindSlot logger_rmq,"RMQ_logger";
        try_motion_program_egm_init;
        ! Initialize the motion program state and log
        ClkReset production_clock;
        ClkStart production_clock;
        production_time := ClkRead(production_clock);
        SetDO motion_program_completed, 0;
        skipped_target_counter:=0; ! initialize skip counter at program start
        current_target_idx:=0;  ! initialize target idx counter at program start
        FOR index FROM 1 TO dim(skipped_targets, 1 ) DO
            skipped_targets{index} := 0;
            ENDFOR
    ENDPROC

    PROC motion_program_fini()
        ClkStop production_clock;
        production_time:=ClkRead(production_clock);
        ErrWrite\I,"Motion Program Complete","Motion Program Completed in "+NumToStr(production_time,0)+" s", \RL2:="Total skipped targets: "+NumToStr(skipped_target_counter,0);
        IDelete motion_trigg_intno;
        ! Set finishing parameters
        SetDO motion_program_completed,1;
        current_target_idx := 0;
    ENDPROC

    PROC run_motion_program_file(string filename)
        ErrWrite\I,"Motion Program Begin","Motion Program Begin";
        close_motion_program_file;
        open_motion_program_file filename,FALSE;
        ErrWrite\I,"Motion Program Start Program","Motion Program Start Program timestamp: "+motion_program_state{task_ind}.program_timestamp;
        IF task_ind=1 THEN
            motion_program_req_log_start;
        ENDIF
        motion_program_run;
        close_motion_program_file;
        IF task_ind=1 THEN
            motion_program_req_log_end;
        ENDIF
    ENDPROC

    PROC open_motion_program_file(string filename,bool preempt)
        VAR num ver;
        VAR tooldata mtool;
        VAR wobjdata mwobj;
        VAR loaddata mgripload;
        VAR string timestamp;
        VAR num egm_cmd;
        VAR num seqno;

        motion_program_state{task_ind}.motion_program_filename:=filename;
        motion_program_clear_bytes;
        Open "RAMDISK:"\File:=filename,motion_program_io_device,\Read\Bin;
        IF NOT try_motion_program_read_num(ver) THEN
            RAISE ERR_FILESIZE;
        ENDIF

        IF ver<>motion_program_file_version THEN
            ErrWrite "Invalid Motion Program","Invalid motion program file version";
            RAISE ERR_INVALID_MP_VERSION;
        ENDIF

        IF NOT try_motion_program_read_td(mtool) THEN
            ErrWrite "Invalid Motion Program Tool","Invalid motion program tool";
            RAISE ERR_INVALID_MP_FILE;
        ENDIF

        IF NOT try_motion_program_read_wd(mwobj) THEN
            ErrWrite "Invalid Motion Program Wobj","Invalid motion program wobj";
            RAISE ERR_INVALID_MP_FILE;
        ENDIF

        IF NOT try_motion_program_read_ld(mgripload) THEN
            ErrWrite "Invalid Motion Program GripLoad","Invalid motion program gripload";
            RAISE ERR_INVALID_MP_FILE;
        ENDIF

        IF NOT try_motion_program_read_string(timestamp) THEN
            ErrWrite "Invalid Motion Program Timestamp","Invalid motion program timestamp";
            RAISE ERR_INVALID_MP_FILE;
        ENDIF

        IF NOT try_motion_program_read_num(seqno) THEN
            ErrWrite "Invalid Motion Program Timestamp","Invalid motion program timestamp";
            RAISE ERR_INVALID_MP_FILE;
        ENDIF

        IF NOT preempt THEN
            motion_program_state{task_ind}.program_seqno:=seqno;
            motion_program_state{task_ind}.program_timestamp:=timestamp;
            IF task_ind=1 THEN
                SetAO motion_program_seqno,seqno;
            ENDIF
        ENDIF

        ErrWrite\I,"Motion Program Opened","Motion Program Opened with timestamp: "+timestamp;

        IF NOT preempt THEN
            motion_program_tool:=mtool;
            motion_program_wobj:=mwobj;
            motion_program_gripload:=mgripload;

            SetSysData motion_program_tool;
            SetSysData motion_program_wobj;
            GripLoad motion_program_gripload;

            IF motion_program_have_egm THEN
                motion_program_egm_enable;
            ELSE
                IF NOT try_motion_program_read_num(egm_cmd) THEN
                    RAISE ERR_INVALID_MP_FILE;
                ENDIF
                IF egm_cmd<>0 THEN
                    RAISE ERR_INVALID_MP_FILE;
                ENDIF
            ENDIF
        ELSE
            IF NOT try_motion_program_read_num(egm_cmd) THEN
                RAISE ERR_INVALID_MP_FILE;
            ENDIF
            IF egm_cmd<>0 THEN
                RAISE ERR_INVALID_MP_FILE;
            ENDIF
        ENDIF

    ENDPROC

    PROC close_motion_program_file()
        VAR string filename;
        filename:=motion_program_state{task_ind}.motion_program_filename;
        motion_program_state{task_ind}.motion_program_filename:="";
        Close motion_program_io_device;
    ERROR
        !SkipWarn;
        TRYNEXT;
    ENDPROC

    PROC motion_program_run()

        VAR bool keepgoing:=TRUE;
        VAR num cmd_num;
        VAR num cmd_op;
        motion_program_state{task_ind}.current_cmd_num:=-1;
        IF task_ind=1 THEN
            SetAO motion_program_current_cmd_num,-1;
        ENDIF
        motion_program_state{task_ind}.running:=TRUE;
        WHILE keepgoing DO
            motion_program_do_preempt;
            keepgoing:=try_motion_program_run_next_cmd(cmd_num,cmd_op);
        ENDWHILE
        WaitRob\ZeroSpeed;
        motion_program_state{task_ind}.running:=FALSE;
    ERROR
        motion_program_state{task_ind}.running:=FALSE;
        RAISE ;
    ENDPROC

    FUNC bool try_motion_program_run_next_cmd(INOUT num cmd_num,INOUT num cmd_op)

        VAR num local_cmd_ind;

        IF NOT (try_motion_program_read_num(cmd_num) AND try_motion_program_read_num(cmd_op)) THEN
            RETURN FALSE;
        ENDIF

        !motion_program_state.current_cmd_num:=cmd_num;
        motion_max_cmd_ind:=motion_max_cmd_ind+1;
        motion_program_state{task_ind}.queued_cmd_num:=motion_max_cmd_ind;
        IF task_ind=1 THEN
            SetAO motion_program_queued_cmd_num,motion_max_cmd_ind;
        ENDIF
        local_cmd_ind:=((motion_max_cmd_ind-1) MOD 128)+1;

        IF (cmd_op DIV 10000)=5 THEN
            ! EGM command numbers start at 50000
            motion_cmd_num_history{local_cmd_ind}:=-1;
            RETURN try_motion_program_run_egm_cmd(cmd_num,cmd_op);
        ENDIF

        TEST cmd_op
        CASE MOTION_PROGRAM_CMD_NOOP:
            RETURN TRUE;
        CASE MOTION_PROGRAM_CMD_MOVEABSJ:
            motion_cmd_num_history{local_cmd_ind}:=-1;
            RETURN try_motion_program_run_moveabsj(cmd_num);
        CASE MOTION_PROGRAM_CMD_MOVEJ:
            motion_cmd_num_history{local_cmd_ind}:=cmd_num;
            RETURN try_motion_program_run_movej(cmd_num);
        CASE MOTION_PROGRAM_CMD_MOVEL:
            motion_cmd_num_history{local_cmd_ind}:=cmd_num;
            RETURN try_motion_program_run_movel(cmd_num);
        CASE MOTION_PROGRAM_CMD_MOVEC:
            motion_cmd_num_history{local_cmd_ind}:=cmd_num;
            RETURN try_motion_program_run_movec(cmd_num);
        CASE MOTION_PROGRAM_CMD_WAIT:
            motion_cmd_num_history{local_cmd_ind}:=-1;
            RETURN try_motion_program_wait(cmd_num);
        CASE MOTION_PROGRAM_CMD_CIRMODE:
            motion_cmd_num_history{local_cmd_ind}:=-1;
            RETURN try_motion_program_set_cirmode(cmd_num);
        CASE MOTION_PROGRAM_CMD_SYNCMOVEON:
            motion_cmd_num_history{local_cmd_ind}:=-1;
            RETURN try_motion_program_sync_move_on(cmd_num);
        CASE MOTION_PROGRAM_CMD_SYNCMOVEOFF:
            motion_cmd_num_history{local_cmd_ind}:=-1;
            RETURN try_motion_program_sync_move_off(cmd_num);
        CASE MOTION_PROGRAM_CMD_SETDO:
            motion_cmd_num_history{local_cmd_ind}:=-1;
            RETURN set_do(cmd_num);
        Case MOTION_PROGRAM_CMD_MOVELRELTOOL:
            motion_cmd_num_history{local_cmd_ind}:=-1;
            RETURN move_reltool(cmd_num);
        CASE MOTION_PROGRAM_CMD_SETGO:
            motion_cmd_num_history{local_cmd_ind}:=-1;
            RETURN set_go(cmd_num);
        CASE MOTION_PROGRAM_CMD_WAITDI:
            motion_cmd_num_history{local_cmd_ind}:=-1;
            RETURN wait_di(cmd_num);
        CASE MOTION_PROGRAM_CMD_WAITGI:
            motion_cmd_num_history{local_cmd_ind}:=-1;
            RETURN wait_gi(cmd_num);
        CASE MOTION_PROGRAM_CMD_CBC:
            motion_cmd_num_history{local_cmd_ind}:=-1;
            RETURN run_CBC(cmd_num);
        CASE MOTION_PROGRAM_CMD_TIE:
            motion_cmd_num_history{local_cmd_ind}:=-1;
            RETURN run_tying_cycle(cmd_num);
        DEFAULT:
            RAISE ERR_INVALID_OPCODE;
        ENDTEST


    ENDFUNC

    FUNC bool try_motion_program_run_moveabsj(num cmd_num)
        VAR jointtarget j;
        VAR speeddata sd;
        VAR zonedata zd;
        IF NOT (
        try_motion_program_read_jt(j)
        AND try_motion_program_read_sd(sd)
        AND try_motion_program_read_zd(zd)
        ) THEN
            RETURN FALSE;
        ENDIF
        IF IsSyncMoveOn() THEN
            MoveAbsJ j,\ID:=cmd_num,sd,zd,motion_program_tool\Wobj:=motion_program_wobj;
        ELSE
            MoveAbsJ j,sd,zd,motion_program_tool\WObj:=motion_program_wobj;
        ENDIF
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_run_movej(num cmd_num)
        VAR robtarget rt;
        VAR speeddata sd;
        VAR zonedata zd;
        IF NOT (
        try_motion_program_read_rt(rt)
        AND try_motion_program_read_sd(sd)
        AND try_motion_program_read_zd(zd)
        ) THEN
            RETURN FALSE;
        ENDIF
        IF IsSyncMoveOn() THEN
            TriggJ rt,\ID:=cmd_num,sd,motion_trigg_data,zd,motion_program_tool\Wobj:=motion_program_wobj;
        ELSE
            TriggJ rt,sd,motion_trigg_data,zd,motion_program_tool\WObj:=motion_program_wobj;
        ENDIF
        RETURN TRUE;

    ENDFUNC

    FUNC bool try_motion_program_run_movel(num cmd_num)
        VAR robtarget rt;
        VAR speeddata sd;
        VAR zonedata zd;
        IF NOT (
        try_motion_program_read_rt(rt)
        AND try_motion_program_read_sd(sd)
        AND try_motion_program_read_zd(zd)
        ) THEN
            RETURN FALSE;
        ENDIF
        ConfL\Off;
        IF IsSyncMoveOn() THEN
            TriggL rt,\ID:=cmd_num,sd,motion_trigg_data,zd,motion_program_tool\Wobj:=motion_program_wobj;
        ELSE
            TriggL rt,sd,motion_trigg_data,zd,motion_program_tool\WObj:=motion_program_wobj;
        ENDIF
        ConfL\On;
        RETURN TRUE;

    ENDFUNC

    FUNC bool try_motion_program_run_movec(num cmd_num)
        VAR robtarget rt1;
        VAR robtarget rt2;
        VAR speeddata sd;
        VAR zonedata zd;
        IF NOT (
        try_motion_program_read_rt(rt1)
        AND try_motion_program_read_rt(rt2)
        AND try_motion_program_read_sd(sd)
        AND try_motion_program_read_zd(zd)
        ) THEN
            RETURN FALSE;
        ENDIF
        IF IsSyncMoveOn() THEN
            TriggC rt1,rt2,\ID:=cmd_num,sd,motion_trigg_data,zd,motion_program_tool\Wobj:=motion_program_wobj;
        ELSE
            TriggC rt1,rt2,sd,motion_trigg_data,zd,motion_program_tool\WObj:=motion_program_wobj;
        ENDIF
        RETURN TRUE;

    ENDFUNC

    FUNC bool set_do(num cmd_num)
        VAR string signal_name;
        VAR signaldo signal_do;
        VAR num signal_value;
        IF NOT (
        try_motion_program_read_string(signal_name)
        AND try_motion_program_read_num(signal_value)
        ) THEN
            RETURN FALSE;
        ENDIF
        AliasIO signal_name,signal_do;
        SetDO signal_do,signal_value;
        RETURN TRUE;
    ENDFUNC

    FUNC bool set_go(num cmd_num)
        VAR string signal_name;
        VAR signalgo signal_go;
        VAR num signal_value;
        IF NOT (
        try_motion_program_read_string(signal_name)
        AND try_motion_program_read_num(signal_value)
        ) THEN
            RETURN FALSE;
        ENDIF
        AliasIO signal_name,signal_go;
        SetGO signal_go,signal_value;
        RETURN TRUE;
    ENDFUNC

    FUNC bool wait_di(num cmd_num)
        VAR string signal_name;
        VAR signaldi signal_di;
        VAR num signal_value;
        IF NOT (
        try_motion_program_read_string(signal_name)
        AND try_motion_program_read_num(signal_value)
        ) THEN
            RETURN FALSE;
        ENDIF
        AliasIO signal_name,signal_di;
        WaitDI signal_di,signal_value;
        RETURN TRUE;
    ENDFUNC


    FUNC bool wait_gi(num cmd_num)
        VAR string signal_name;
        VAR signalgi signal_gi;
        VAR num signal_value;
        IF NOT (
        try_motion_program_read_string(signal_name)
        AND try_motion_program_read_num(signal_value)
        ) THEN
            RETURN FALSE;
        ENDIF
        AliasIO signal_name,signal_gi;
        WaitGI signal_gi,signal_value;
        RETURN TRUE;
    ENDFUNC

    FUNC bool move_reltool(num cmd_num)
        ! Move robot away in Z by given distance
        VAR robtarget rt;
        VAR num offset_distance:=-100;
        VAR speeddata sd;
        IF NOT (
            try_motion_program_read_sd(sd)
            AND try_motion_program_read_num(offset_distance)
            ) THEN
            RETURN FALSE;
        ENDIF
        rt:=CRobT(\Tool:=motion_program_tool,\WObj:=motion_program_wobj);
        ConfL\Off;
        MoveL RelTool(rt,0,0,offset_distance),sd,fine,motion_program_tool\WObj:=motion_program_wobj;
        ConfL\On;
        RETURN TRUE;
    ENDFUNC

    FUNC bool run_CBC(num cmd_num)
        CyclicBrakeCheck;
        RETURN TRUE;
    ENDFUNC

    FUNC bool run_tying_cycle(num cmd_num)
        VAR robtarget rt;
        VAR robtarget corrected_rt;
        VAR robtarget approach_rt;
        VAR robtarget rotated_approach_rt;
        VAR robtarget search_horizontal_rt;
        VAR robtarget search_vertical_rt;
        VAR speeddata sd;
        VAR zonedata zd;
        VAR signalgi signal_gi;
        VAR signalgo signal_go;
        VAR num approach_offsetZ:=150;
        VAR num no_tie;
        VAR num debug_tying;
        VAR num rotate_clockwise;
        VAR num tying_offsetX:=99999;
        VAR num tying_offsetY:=99999;
        VAR num tying_offsetZ:=99999;
        VAR string state_signal_str:="xtie_state";
        VAR string command_signal_str:="xtie_command";
        VAR bool offset_too_large;
        VAR bool vertical_bar_inaccurate:=FALSE;
        VAR bool horizontal_bar_inaccurate:=FALSE;
        VAR num tying_target_idx;
        VAR num error_x;
        VAR num error_y;
        VAR num error_z;
        CONST num sensor_rotation_angle:=90;
        CONST num tying_gap_distance:=5;
        CONST num max_deviation_xy:=35;
        CONST num max_deviation_z:=40;
        CONST num min_accuracy:=80;
        CONST num search_distance:=20;!mm

        IF NOT (
            try_motion_program_read_rt(rt)
            AND try_motion_program_read_sd(sd)
            AND try_motion_program_read_zd(zd)
            AND try_motion_program_read_num(approach_offsetZ)
            AND try_motion_program_read_num(no_tie)
            AND try_motion_program_read_num(tying_target_idx)
            AND try_motion_program_read_num(rotate_clockwise)
            AND try_motion_program_read_num(debug_tying)
            ) THEN
            RETURN FALSE;
        ENDIF
        current_target_idx:=tying_target_idx;
        approach_rt:=RelTool(rt,0,0,approach_offsetZ);
        IF rotate_clockwise=1 THEN
            rotated_approach_rt:=RelTool(approach_rt,0,0,0,\Rz:=sensor_rotation_angle);
        ELSE
            rotated_approach_rt:=RelTool(approach_rt,0,0,0,\Rz:=-sensor_rotation_angle);
        ENDIF
        ConfL\Off;
        ! Move to approach target & turn on laser
        MoveLDO approach_rt,sd,fine,motion_program_tool\WObj:=motion_program_wobj,oxm_laser_on,1;
        StopMove;
        WaitTime 1.5;
        IF debug_tying=1 THEN
            Stop;
        ENDIF
        ! Check if profile is accurate
        IF matching_accuracy<min_accuracy THEN
            ! Try moving in Y 10mm
            ErrWrite\I,"Attempting shift search for vertical bar","Shifting -"+ NumToStr(search_distance,0)+" mm in Y";
            search_vertical_rt:=RelTool(approach_rt,0,-search_distance,0);
            StartMove;
            MoveL search_vertical_rt,sd,fine,motion_program_tool\WObj:=motion_program_wobj;
            StopMove;
            WaitTime 2.5;
            IF debug_tying=1 THEN
                Stop;
            ENDIF
            IF matching_accuracy>min_accuracy THEN
                vertical_bar_inaccurate:=False;
                tying_offsetZ:=z_offset-tying_gap_distance;
                tying_offsetX:=x_offset;
            ElSE
                vertical_bar_inaccurate:=TRUE;
            ENDIF
            StartMove;
            MoveL approach_rt,sd,fine,motion_program_tool\WObj:=motion_program_wobj;
        ELSE
            vertical_bar_inaccurate:=FALSE;
            tying_offsetZ:=z_offset-tying_gap_distance;
            tying_offsetX:=x_offset;
        ENDIF
        StartMove;
        if vertical_bar_inaccurate THEN
            ! skip the horizontal bar measurement
            ErrWrite\I,"Vertical bar measurement failed", "skipping target early";
        ELSE
            MoveL rotated_approach_rt,sd,fine,motion_program_tool\WObj:=motion_program_wobj;
            StopMove;
            WaitTime 1.5;
            IF debug_tying=1 THEN
                Stop;
            ENDIF
            ! Check if profile is accurate
            IF matching_accuracy<min_accuracy THEN
                ! Try moving in Y 10mm
                ErrWrite\I,"Attempting shift search for horizontal bar","Shifting -"+ NumToStr(search_distance,0)+"mm in Y";
                search_horizontal_rt:=RelTool(rotated_approach_rt,0,-search_distance,0);
                StartMove;
                MoveL search_horizontal_rt,sd,fine,motion_program_tool\WObj:=motion_program_wobj;
                StopMove;
                WaitTime 2.5;
                IF debug_tying=1 THEN
                    Stop;
                ENDIF
                IF matching_accuracy>min_accuracy THEN
                    horizontal_bar_inaccurate:=False;
                    IF rotate_clockwise=1 THEN
                        tying_offsetY:=y_offset;
                    ELSE
                        tying_offsetY:=-1*y_offset;
                    ENDIF
                ElSE
                    horizontal_bar_inaccurate:=TRUE;
                ENDIF
                StartMove;
                MoveL rotated_approach_rt,sd,fine,motion_program_tool\WObj:=motion_program_wobj;
            ELSE
                horizontal_bar_inaccurate:=FALSE;
                IF rotate_clockwise=1 THEN
                    tying_offsetY:=y_offset;
                ELSE
                    tying_offsetY:=-1*y_offset;
                ENDIF
            ENDIF
        ENDIF
        
        StartMove;
        MoveLDO approach_rt,sd,fine,motion_program_tool\WObj:=motion_program_wobj,oxm_laser_on,0;
        error_z:=abs(approach_offsetZ)-abs(tying_offsetZ);
        offset_too_large:=abs(error_z)>max_deviation_z OR ABS(tying_offsetX)>max_deviation_xy OR ABS(tying_offsetY)>max_deviation_xy;
        IF offset_too_large OR horizontal_bar_inaccurate OR vertical_bar_inaccurate THEN
            TPWrite "WARNING offsets too large or maybe NaN, potential collision!";
            TPWrite "X:"+NumToStr(tying_offsetX,1)+"Y:"+NumToStr(tying_offsetY,1)+"Z:"+NumToStr(tying_offsetZ,1)+"("+NumToStr(abs(approach_offsetZ)-tying_gap_distance,1)+")";
            TPWrite "Skipping target! - horizontal_bar_inaccurate =",\Bool:=horizontal_bar_inaccurate;
            TPWrite "Skipping target! - vertical_bar_inaccurate =",\Bool:=vertical_bar_inaccurate;
            ErrWrite\I,"Skipping target:"+NumToStr(current_target_idx,0),
                "Skipping target due to measurement offsets being too large!"
                \RL2:="dx: "+NumToStr(tying_offsetX,1)+" dy: "+NumToStr(tying_offsetY,1)+" dz: "+NumToStr(tying_offsetZ,1)+" ("+NumToStr(abs(approach_offsetZ)-tying_gap_distance,1)+")",
                \RL3:="Max error z"+NumToStr(max_deviation_z,1)+"max error xy:"+NumToStr(max_deviation_xy,1),
                \RL4:="profile inaccurate H:"+ValToStr(horizontal_bar_inaccurate)+"V:"+ValToStr(vertical_bar_inaccurate);
            skipped_targets{tying_target_idx} := tying_target_idx;
            Incr skipped_target_counter;
        ELSE
            ErrWrite\I,"adjusting target:"+NumToStr(current_target_idx,0),
                "dx: "+NumToStr(tying_offsetX,1),
                \RL2:=" dy: "+NumToStr(tying_offsetY,1),
                \RL3:=" dz: "+NumToStr(tying_offsetZ,1)+" (~"+NumToStr(abs(approach_offsetZ)-tying_gap_distance,1)+")";
            corrected_rt:=RelTool(approach_rt,-tying_offsetX,-tying_offsetY,tying_offsetZ);
            ! Move to tying target
            MoveL corrected_rt,sd,fine,motion_program_tool\WObj:=motion_program_wobj;
            ! Check tying tool state and send tying command
            if no_tie=0 THEN
                AliasIO state_signal_str,signal_gi;
                AliasIO command_signal_str,signal_go;
                WaitGI signal_gi,3;
                ! 3 == ST_XTIE_READY
                SetGO signal_go,4;
                ! 4 == Start command
                !! Add Trap routine here in case of error
                WaitGI signal_gi,5;
                ! 5 == ST_TIE_DONE
            ENDIF

            ! Move to approach (exit) target
            IF no_tie=0 THEN
                ! Move to approach (exit) target and only clear once at the target
                MoveLGO approach_rt,sd,z50,motion_program_tool\WObj:=motion_program_wobj,signal_go,\Value:=7;
            ELSE
                MoveL approach_rt,sd,z50,motion_program_tool\WObj:=motion_program_wobj;
            ENDIF
        ENDIF

        ConfL\On;
        IF task_ind=1 THEN
            SetAO motion_program_current_cmd_num,cmd_num;
        ENDIF
        RETURN TRUE;

    ENDFUNC

    FUNC bool try_motion_program_wait(num cmd_num)
        VAR num t;
        IF NOT try_motion_program_read_num(t) THEN
            RETURN FALSE;
        ENDIF
        WaitRob\ZeroSpeed;
        motion_program_state{task_ind}.current_cmd_num:=cmd_num;
        IF task_ind=1 THEN
            SetAO motion_program_current_cmd_num,cmd_num;
        ENDIF
        WaitTime t;
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_set_cirmode(num cmd_num)
        VAR num switch;
        IF NOT try_motion_program_read_num(switch) THEN
            RETURN FALSE;
        ENDIF
        motion_program_state{task_ind}.current_cmd_num:=cmd_num;
        IF task_ind=1 THEN
            SetAO motion_program_current_cmd_num,cmd_num;
        ENDIF
        TEST switch
        CASE 1:
            CirPathMode\PathFrame;
        CASE 2:
            CirPathMode\ObjectFrame;
        CASE 3:
            CirPathMode\CirPointOri;
        CASE 4:
            CirPathMode\Wrist45;
        CASE 5:
            CirPathMode\Wrist46;
        CASE 6:
            CirPathMode\Wrist56;
        ENDTEST
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_sync_move_on(num cmd_num)
        SyncMoveOn motion_program_sync1,task_list;
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_sync_move_off(num cmd_num)
        SyncMoveOff motion_program_sync2;
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_read_jt(INOUT jointtarget j)
        IF NOT (
        try_motion_program_read_num(j.robax.rax_1)
        AND try_motion_program_read_num(j.robax.rax_2)
        AND try_motion_program_read_num(j.robax.rax_3)
        AND try_motion_program_read_num(j.robax.rax_4)
        AND try_motion_program_read_num(j.robax.rax_5)
        AND try_motion_program_read_num(j.robax.rax_6)
        AND try_motion_program_read_num(j.extax.eax_a)
        AND try_motion_program_read_num(j.extax.eax_b)
        AND try_motion_program_read_num(j.extax.eax_c)
        AND try_motion_program_read_num(j.extax.eax_d)
        AND try_motion_program_read_num(j.extax.eax_e)
        AND try_motion_program_read_num(j.extax.eax_f)
        ) THEN
            RETURN FALSE;
        ENDIF
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_read_sd(INOUT speeddata sd)
        IF NOT (
        try_motion_program_read_num(sd.v_tcp)
        AND try_motion_program_read_num(sd.v_ori)
        AND try_motion_program_read_num(sd.v_leax)
        AND try_motion_program_read_num(sd.v_reax)
        ) THEN
            RETURN FALSE;
        ENDIF
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_read_zd(INOUT zonedata zd)
        VAR num finep_num:=0;
        IF NOT (
        try_motion_program_read_num(finep_num)
        AND try_motion_program_read_num(zd.pzone_tcp)
        AND try_motion_program_read_num(zd.pzone_ori)
        AND try_motion_program_read_num(zd.pzone_eax)
        AND try_motion_program_read_num(zd.zone_ori)
        AND try_motion_program_read_num(zd.zone_leax)
        AND try_motion_program_read_num(zd.zone_reax)
        ) THEN
            RETURN FALSE;
        ENDIF
        zd.finep:=finep_num<>0;
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_read_pose(INOUT pose p)
        IF NOT (
            try_motion_program_read_num(p.trans.x)
            AND try_motion_program_read_num(p.trans.y)
            AND try_motion_program_read_num(p.trans.z)
            AND try_motion_program_read_num(p.rot.q1)
            AND try_motion_program_read_num(p.rot.q2)
            AND try_motion_program_read_num(p.rot.q3)
            AND try_motion_program_read_num(p.rot.q4)
        ) THEN
            RETURN FALSE;
        ENDIF
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_read_rt(INOUT robtarget rt)
        IF NOT (
            try_motion_program_read_num(rt.trans.x)
            AND try_motion_program_read_num(rt.trans.y)
            AND try_motion_program_read_num(rt.trans.z)
            AND try_motion_program_read_num(rt.rot.q1)
            AND try_motion_program_read_num(rt.rot.q2)
            AND try_motion_program_read_num(rt.rot.q3)
            AND try_motion_program_read_num(rt.rot.q4)
            AND try_motion_program_read_num(rt.robconf.cf1)
            AND try_motion_program_read_num(rt.robconf.cf4)
            AND try_motion_program_read_num(rt.robconf.cf6)
            AND try_motion_program_read_num(rt.robconf.cfx)
            AND try_motion_program_read_num(rt.extax.eax_a)
            AND try_motion_program_read_num(rt.extax.eax_b)
            AND try_motion_program_read_num(rt.extax.eax_c)
            AND try_motion_program_read_num(rt.extax.eax_d)
            AND try_motion_program_read_num(rt.extax.eax_e)
            AND try_motion_program_read_num(rt.extax.eax_f)
        ) THEN
            RETURN FALSE;
        ENDIF
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_read_td(INOUT tooldata td)
        VAR num robhold_num;
        IF NOT (
            try_motion_program_read_num(robhold_num)
            AND try_motion_program_read_num(td.tframe.trans.x)
            AND try_motion_program_read_num(td.tframe.trans.y)
            AND try_motion_program_read_num(td.tframe.trans.z)
            AND try_motion_program_read_num(td.tframe.rot.q1)
            AND try_motion_program_read_num(td.tframe.rot.q2)
            AND try_motion_program_read_num(td.tframe.rot.q3)
            AND try_motion_program_read_num(td.tframe.rot.q4)
            AND try_motion_program_read_num(td.tload.mass)
            AND try_motion_program_read_num(td.tload.cog.x)
            AND try_motion_program_read_num(td.tload.cog.y)
            AND try_motion_program_read_num(td.tload.cog.z)
            AND try_motion_program_read_num(td.tload.aom.q1)
            AND try_motion_program_read_num(td.tload.aom.q2)
            AND try_motion_program_read_num(td.tload.aom.q3)
            AND try_motion_program_read_num(td.tload.aom.q4)
            AND try_motion_program_read_num(td.tload.ix)
            AND try_motion_program_read_num(td.tload.iy)
            AND try_motion_program_read_num(td.tload.iz)
        )
        THEN
            RETURN FALSE;
        ENDIF
        td.robhold:=robhold_num<>0;
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_read_ld(INOUT loaddata ld)
        IF NOT (
            try_motion_program_read_num(ld.mass)
            AND try_motion_program_read_num(ld.cog.x)
            AND try_motion_program_read_num(ld.cog.y)
            AND try_motion_program_read_num(ld.cog.z)
            AND try_motion_program_read_num(ld.aom.q1)
            AND try_motion_program_read_num(ld.aom.q2)
            AND try_motion_program_read_num(ld.aom.q3)
            AND try_motion_program_read_num(ld.aom.q4)
            AND try_motion_program_read_num(ld.ix)
            AND try_motion_program_read_num(ld.iy)
            AND try_motion_program_read_num(ld.iz)
        )
        THEN
            RETURN FALSE;
        ENDIF
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_read_wd(INOUT wobjdata wd)
        VAR num robhold_num;
        VAR num ufprog_num;
        IF NOT (
            try_motion_program_read_num(robhold_num)
            AND try_motion_program_read_num(ufprog_num)
            AND try_motion_program_read_string(wd.ufmec)
            AND try_motion_program_read_num(wd.uframe.trans.x)
            AND try_motion_program_read_num(wd.uframe.trans.y)
            AND try_motion_program_read_num(wd.uframe.trans.z)
            AND try_motion_program_read_num(wd.uframe.rot.q1)
            AND try_motion_program_read_num(wd.uframe.rot.q2)
            AND try_motion_program_read_num(wd.uframe.rot.q3)
            AND try_motion_program_read_num(wd.uframe.rot.q4)
            AND try_motion_program_read_num(wd.oframe.trans.x)
            AND try_motion_program_read_num(wd.oframe.trans.y)
            AND try_motion_program_read_num(wd.oframe.trans.z)
            AND try_motion_program_read_num(wd.oframe.rot.q1)
            AND try_motion_program_read_num(wd.oframe.rot.q2)
            AND try_motion_program_read_num(wd.oframe.rot.q3)
            AND try_motion_program_read_num(wd.oframe.rot.q4)
        )
        THEN
            RETURN FALSE;
        ENDIF
        wd.robhold:=robhold_num<>0;
        wd.ufprog:=ufprog_num<>0;
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_fill_bytes()
        IF RawBytesLen(motion_program_bytes)=0 OR motion_program_bytes_offset>RawBytesLen(motion_program_bytes) THEN
            ClearRawBytes motion_program_bytes;
            motion_program_bytes_offset:=1;
            ReadRawBytes motion_program_io_device,motion_program_bytes;
            IF RawBytesLen(motion_program_bytes)=0 THEN
                RETURN FALSE;
            ENDIF
        ENDIF
        RETURN TRUE;
    ERROR
        IF ERRNO=ERR_RANYBIN_EOF THEN
            SkipWarn;
            TRYNEXT;
        ENDIF
    ENDFUNC

    PROC motion_program_clear_bytes()
        ClearRawBytes motion_program_bytes;
    ENDPROC

    FUNC bool try_motion_program_read_num(INOUT num val)
        IF NOT try_motion_program_fill_bytes() THEN
            val:=0;
            RETURN FALSE;
        ENDIF
        UnpackRawBytes motion_program_bytes,motion_program_bytes_offset,val,\Float4;
        motion_program_bytes_offset:=motion_program_bytes_offset+4;
        RETURN TRUE;
    ENDFUNC

    FUNC bool try_motion_program_read_string(INOUT string val)
        VAR num str_len;
        VAR string str1;
        VAR num str1_len;
        VAR string str2;
        VAR num str2_len;
        IF NOT (
            try_motion_program_fill_bytes()
            AND try_motion_program_read_num(str_len)
            AND try_motion_program_fill_bytes()
        )
        THEN
            val:="";
            RETURN FALSE;
        ENDIF
        IF RawBytesLen(motion_program_bytes)>=(motion_program_bytes_offset+31) THEN
            UnpackRawBytes motion_program_bytes,motion_program_bytes_offset,val,\ASCII:=str_len;
            motion_program_bytes_offset:=motion_program_bytes_offset+32;
            RETURN TRUE;
        ELSE
            str1_len:=(RawBytesLen(motion_program_bytes)+1)-motion_program_bytes_offset;
            IF str1_len>=str_len THEN
                UnpackRawBytes motion_program_bytes,motion_program_bytes_offset,val,\ASCII:=str_len;
                motion_program_bytes_offset:=motion_program_bytes_offset+str1_len;
                IF NOT try_motion_program_fill_bytes() THEN
                    RETURN FALSE;
                ENDIF
                motion_program_bytes_offset:=motion_program_bytes_offset+(32-str1_len);
                RETURN TRUE;
            ELSE
                UnpackRawBytes motion_program_bytes,motion_program_bytes_offset,str1,\ASCII:=str1_len;
                motion_program_bytes_offset:=motion_program_bytes_offset+str1_len;
                IF NOT try_motion_program_fill_bytes() THEN
                    RETURN FALSE;
                ENDIF
                str2_len:=str_len-str1_len;
                UnpackRawBytes motion_program_bytes,motion_program_bytes_offset,str2,\ASCII:=str2_len;
                motion_program_bytes_offset:=motion_program_bytes_offset+(32-str1_len);
                val:=str1+str2;
                RETURN TRUE;
            ENDIF
        ENDIF

    ENDFUNC

    PROC motion_program_req_log_start()
        VAR string msg{2};
        msg{1}:=motion_program_state{task_ind}.program_timestamp;
        msg{2}:=motion_program_state{task_ind}.program_timestamp;
        IF MOTION_PROGRAM_DRIVER_MODE=1 THEN
            msg{2}:="motion_program---seqno-"+NumToStr(motion_program_state{task_ind}.program_seqno,0);
        ENDIF
        RMQSendMessage logger_rmq,msg;
    ENDPROC

    PROC motion_program_req_log_end()
        VAR string msg{2};
        RMQSendMessage logger_rmq,msg;
    ENDPROC

    PROC motion_program_do_preempt()
        VAR string filename;
        IF motion_program_preempt>motion_program_state{task_ind}.preempt_current THEN
            IF motion_max_cmd_ind=motion_program_preempt_cmd_num THEN
                IF task_ind=1 THEN
                    filename:=StrFormat("motion_program_p{1}"\Arg1:=NumToStr(motion_program_preempt,0));
                ELSE
                    filename:=StrFormat("motion_program2_p{1}"\Arg1:=NumToStr(motion_program_preempt,0));
                ENDIF
                IF MOTION_PROGRAM_DRIVER_MODE=1 THEN
                    filename:=filename+"---seqno-"+NumToStr(motion_program_state{task_ind}.program_seqno,0);
                ENDIF
                filename:=filename+".bin";
                ErrWrite\I,"Preempting Motion Program","Preempting motion program with file "+filename;
                IF task_ind=1 THEN
                    SetAO motion_program_preempt_current,motion_program_preempt;
                ENDIF
                motion_program_state{task_ind}.preempt_current:=motion_program_preempt;
                close_motion_program_file;
                open_motion_program_file filename,TRUE;
            ELSEIF motion_max_cmd_ind>motion_program_preempt_cmd_num THEN
                ErrWrite "Missed Preempt","Preempt command number missed";
                RAISE ERR_MISSED_PREEMPT;
            ENDIF
        ENDIF
    ENDPROC

    TRAP motion_trigg_trap
        VAR num cmd_ind;
        VAR num local_cmd_ind;
        VAR num cmd_num:=-1;
        WHILE cmd_num=-1 AND (NOT motion_current_cmd_ind>motion_max_cmd_ind) DO
            motion_current_cmd_ind:=motion_current_cmd_ind+1;
            IF motion_current_cmd_ind>motion_max_cmd_ind THEN
                cmd_ind:=motion_max_cmd_ind;
            ELSE
                cmd_ind:=motion_current_cmd_ind;
            ENDIF
            local_cmd_ind:=((cmd_ind-1) MOD 128)+1;
            cmd_num:=motion_cmd_num_history{local_cmd_ind};
        ENDWHILE

        IF cmd_num<>-1 THEN
            motion_program_state{task_ind}.current_cmd_num:=cmd_num;
            IF task_ind=1 THEN
                SetAO motion_program_current_cmd_num,cmd_num;
            ENDIF
        ENDIF
    ENDTRAP

    PROC try_motion_program_egm_init()
        motion_program_egm_init;
    ERROR
        IF ERRNO=ERR_REFUNKPRC THEN
            SkipWarn;
            motion_program_have_egm:=FALSE;
            TRYNEXT;
        ENDIF
    ENDPROC

    PROC motion_program_main_driver_mode()
        IDelete motion_program_driver_abort_into;
        CONNECT motion_program_driver_abort_into WITH motion_program_abort_driver_mode;
        motion_program_driver_seqno:=-1;
        motion_program_init;
        motion_program_egm_start_stream;
        WaitUntil motion_program_seqno_command>motion_program_seqno_started AND motion_program_driver_abort=0;
        SetAO motion_program_seqno_started,motion_program_seqno_command;
        ISignalDO motion_program_driver_abort,1,motion_program_driver_abort_into;
        motion_program_driver_seqno:=motion_program_seqno_command;
        ErrWrite\I,"Motion Program Driver Begin Program",StrFormat("Motion Program Driver Begin Program seqno "\Arg1:=NumToStr(motion_program_driver_seqno,0));
        IF task_ind=1 THEN
            motion_program_filename:="motion_program---seqno-"+NumToStr(motion_program_driver_seqno,0)+".bin";
        ELSEIF task_ind=2 THEN
            motion_program_filename:="motion_program2---seqno-"+NumToStr(motion_program_driver_seqno,0)+".bin";
        ENDIF
        run_motion_program_file(motion_program_filename);
        !motion_program_reset_handler;
        motion_program_fini_driver_mode;
        ExitCycle;
    ERROR
        IF motion_program_driver_seqno>motion_program_seqno_complete THEN
            SetAO motion_program_seqno_complete,motion_program_driver_seqno;
            ErrWrite\I,"Motion Program Driver Program Complete","Motion Program Complete";
        ENDIF
        RAISE ;
    ENDPROC

    PROC motion_program_fini_driver_mode()
        IF MOTION_PROGRAM_DRIVER_MODE=1 THEN
            IF motion_program_driver_seqno>motion_program_seqno_complete THEN
                SetAO motion_program_seqno_complete,motion_program_driver_seqno;
                ErrWrite\I,"Motion Program Driver Program Complete","Motion Program Complete";
            ENDIF
        ENDIF
    ENDPROC

    TRAP motion_program_abort_driver_mode
        motion_program_fini_driver_mode;
        ExitCycle;
    ENDTRAP

    PROC motion_program_stop_handler()

    ENDPROC

ENDMODULE
