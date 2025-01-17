library IEEE;
use IEEE.std_logic_1164.all;  
use IEEE.numeric_std.all; 

use work.pJoypad.all;

entity joypad_pad is
   port 
   (
      clk1x                : in  std_logic;
      ce                   : in  std_logic;
      reset                : in  std_logic;
      
      joypad               : in  joypad_t;
      rumble               : out std_logic_vector(15 downto 0);
      padMode              : out std_logic_vector(1 downto 0);
      portNr               : in integer range 0 to 1;

      isPal                : in  std_logic;
      
      selected             : in  std_logic;
      actionNext           : in  std_logic := '0';
      transmitting         : in  std_logic := '0';
      transmitValue        : in  std_logic_vector(7 downto 0);
      
      isActive             : out std_logic := '0';
      slotIdle             : in  std_logic;
      
      receiveValid         : out std_logic;
      receiveBuffer        : out std_logic_vector(7 downto 0);
      ack                  : out std_logic;

      MouseEvent           : in  std_logic;
      MouseLeft            : in  std_logic;
      MouseRight           : in  std_logic;
      MouseX               : in  signed(8 downto 0);
      MouseY               : in  signed(8 downto 0);
      GunX                 : in  unsigned(7 downto 0);
      GunY_scanlines       : in  unsigned(8 downto 0);
      GunAimOffscreen      : in  std_logic;
      
      ss_in                : in  std_logic_vector(31 downto 0);
      ss_out               : out std_logic_vector(31 downto 0)
   );
end entity;

architecture arch of joypad_pad is
   
   type tcontrollerState is
   (
      IDLE,
      READY,
      ID,
      BUTTONLSB,
      BUTTONMSB,
      ANALOGRIGHTX,
      ANALOGRIGHTY,
      ANALOGLEFTX,
      ANALOGLEFTY,
      MOUSEBUTTONSLSB,
      MOUSEBUTTONSMSB,
      MOUSEAXISX,
      MOUSEAXISY,
      GUNCONBUTTONSLSB,
      GUNCONBUTTONSMSB,
      GUNCONXLSB,
      GUNCONXMSB,
      GUNCONYLSB,
      GUNCONYMSB,
      NEGCONBUTTONMSB,
      NEGCONSTEERING,
      NEGCONANALOGI,
      NEGCONANALOGII,
      NEGCONANALOGL,
      JUSTIFBUTTONSLSB,
      JUSTIFBUTTONSMSB,
      CHANGECONFIG,
      SETSTATELSB,
      SETSTATEMSB,
      GETSTATE,
      COMMAND46,
      COMMAND47,
      COMMAND4C,
      UPDATERUMBLE,
      ROMRESPONSE
   );
   signal controllerState : tcontrollerState := IDLE;
   signal nextState : tcontrollerState := IDLE;

   type tcommands is
   (
      COMMAND_NONE,
      COMMAND_READ_INPUTS,
      COMMAND_CHANGE_CONFIG_MODE,
      COMMAND_GET_STATE,
      COMMAND_SET_STATE,
      COMMAND_46,
      COMMAND_47,
      COMMAND_4C,
      COMMAND_RUMBLE,
      COMMAND_UNKNOWN
   );
   signal command : tcommands := COMMAND_NONE;

   signal analogPadSave   : std_logic := '0';
   signal rumbleOnFirst   : std_logic := '0';
   signal mouseSave       : std_logic := '0';
   signal gunConSave      : std_logic := '0';
   signal neGconSave      : std_logic := '0';
   signal justifSave      : std_logic := '0';
   signal dsSave          : std_logic := '0';

   signal prevMouseEvent  : std_logic := '0';
   signal MouseLeft_1     : std_logic := '0';
   signal switchmode      : std_logic := '0'; 

   signal mouseAccX       : signed(9 downto 0) := (others => '0');
   signal mouseAccY       : signed(9 downto 0) := (others => '0');

   signal mouseOutX       : signed(7 downto 0) := (others => '0');
   signal mouseOutY       : signed(7 downto 0) := (others => '0');

   signal gunOffScreen    : std_logic := '0';
   signal gunConX_8MHz    : std_logic_vector(8 downto 0) := (others => '0');
   signal gunConY         : std_logic_vector(8 downto 0) := (others => '0');
  
   signal analogLarge     : std_logic_vector(7 downto 0);
  
   type portState is record
      dsConfigMode   : std_logic;
      dsRumbleMode   : std_logic; -- return to zero when switching mode manually?
      dsAnalogMode   : std_logic;
      dsAnalogLock   : std_logic;
      dsRumbleConfig : std_logic_vector(47 downto 0);
      rumble         : std_logic_vector(15 downto 0);
      dsRumbleIndexS : integer range -1 to 5;
      dsRumbleIndexL : integer range -1 to 5;
   end record;
   type portState_array is array(0 to 1) of portState;
   signal portStates : portState_array;

   signal dsConfigModeSave  : std_logic := '0';
   signal dsAnalogModeSave  : std_logic := '0';

   type tresponse is array (natural range <>) of std_logic_vector(7 downto 0);
   constant response : tresponse :=(
      x"00", x"00", x"00", x"00", x"00", x"00", -- padding
      x"01", x"02",                             -- analog get part 1
      x"02", x"01", x"00",                      -- analog get part 2
      x"00", x"01", x"02", x"00", x"0A",        -- 46+00
      x"00", x"01", x"01", x"01", x"14",        -- 46+01
      x"00", x"02", x"00", x"01", x"00",        -- 47
      x"00", x"00", x"04", x"00", x"00",        -- 4C+00
      x"00", x"00", x"07", x"00", x"00"         -- 4C+01
   );

   signal rom_pointer : integer range 0 to 36;
   signal bytecount   : integer range 0 to 6;
   signal rumblecount : integer range 0 to 5;
  
begin 

   rumble <= portStates(portNr).rumble;
   
   padMode <= portStates(1).dsAnalogMode & portStates(0).dsAnalogMode;
   
   ss_out(0)            <= portStates(0).dsConfigMode;  
   ss_out(1)            <= portStates(0).dsRumbleMode;  
   ss_out(2)            <= portStates(0).dsAnalogMode;  
   ss_out(3)            <= portStates(0).dsAnalogLock;  
   ss_out( 7 downto 4)  <= std_logic_vector(to_signed(portStates(0).dsRumbleIndexS,4));   
   ss_out(11 downto 8)  <= std_logic_vector(to_signed(portStates(0).dsRumbleIndexL,4));   
   ss_out(31 downto 12) <= (others => '0');
   
   process (clk1x)
      variable mouseIncX            : signed(9 downto 0) := (others => '0');
      variable mouseIncY            : signed(9 downto 0) := (others => '0');
      variable newMouseAccX         : signed(9 downto 0) := (others => '0');
      variable newMouseAccY         : signed(9 downto 0) := (others => '0');
      variable newMouseAccClippedX  : signed(9 downto 0) := (others => '0');
      variable newMouseAccClippedY  : signed(9 downto 0) := (others => '0');
      variable newAnalog            : signed(8 downto 0) := (others => '0');
      variable newPedal             : signed(7 downto 0) := (others => '0');
   begin
      if rising_edge(clk1x) then
      
         receiveValid   <= '0';
         receiveBuffer  <= x"00";
      
         ack <= '0';
         
         -- increase analog values by 1/8 and convert from -127..127 to 0..255
         newAnalog := resize(joypad.Analog2X, 9);
         case (controllerState) is
            when ANALOGRIGHTX => newAnalog := resize(joypad.Analog2X, 9);
            when ANALOGRIGHTY => newAnalog := resize(joypad.Analog2Y, 9);
            when ANALOGLEFTX  => newAnalog := resize(joypad.Analog1X, 9);
            when ANALOGLEFTY  => newAnalog := resize(joypad.Analog1Y, 9);
            when others => null;
         end case;
         
         newAnalog := newAnalog + newAnalog / 8;

         if    (newAnalog > 127) then newAnalog := to_signed(127, 9); 
         elsif (newAnalog < -128) then newAnalog := to_signed(-128, 9); 
         end if;
         
         analogLarge <= std_logic_vector(to_unsigned(to_integer(newAnalog) + 128, 8));
      
         if (reset = '1') then
         
            controllerState <= IDLE;
            isActive        <= '0';
            
            portStates      <= (others => ('0', '0', '0', '0', (others => '1'), (others => '0'), -1, -1));
            
            -- only save state for slot 1
            portStates(0).dsConfigMode   <= ss_in(0);          
            portStates(0).dsRumbleMode   <= ss_in(1);                   
            portStates(0).dsAnalogMode   <= ss_in(2);                   
            portStates(0).dsAnalogLock   <= ss_in(3);                   
            portStates(0).dsRumbleIndexS <= to_integer(signed(ss_in( 7 downto 4)));         
            portStates(0).dsRumbleIndexL <= to_integer(signed(ss_in(11 downto 8)));         

         elsif (ce = '1') then
         
            if (selected = '0') then
               isActive        <= '0';
               controllerState <= IDLE;
               command         <= COMMAND_NONE;
            elsif (joypad.PadPortDS = '1') then
               if (portStates(portNr).dsAnalogLock = '0') then
                  if (switchmode = '1' and portNr = 0) then
                     switchmode <= '0';
                     portStates(0).dsAnalogMode <= not portStates(0).dsAnalogMode;
                     portStates(0).dsRumbleMode <= '0';
                  end if;
                  if (joypad.KeyL3 = '1' and joypad.KeyR3 = '1' and joypad.KeyUp = '1') then 
                     portStates(portNr).dsAnalogMode <= '1';
                     portStates(portNr).dsRumbleMode <= '0';
                  end if;
                  if (joypad.KeyL3 = '1' and joypad.KeyR3 = '1' and joypad.KeyDown = '1') then 
                     portStates(portNr).dsAnalogMode <= '0';
                     portStates(portNr).dsRumbleMode <= '0';
                  end if;
               end if;
            else
               portStates(portNr).dsConfigMode   <= '0';
               portStates(portNr).dsRumbleMode   <= '0';
               portStates(portNr).dsAnalogMode   <= '0';
               portStates(portNr).dsAnalogLock   <= '0';
               portStates(portNr).dsRumbleConfig <= (others => '0');
               portStates(portNr).dsRumbleIndexS <= -1;
               portStates(portNr).dsRumbleIndexL <= -1;
            end if;
            
            MouseLeft_1 <= MouseLeft;
            if (MouseLeft = '1' and MouseLeft_1 = '0') then
               switchmode <= '1';
            end if;

            prevMouseEvent  <= MouseEvent;
            if (prevMouseEvent /= MouseEvent) then
               mouseIncX := resize(MouseX, mouseIncX'length);
               mouseIncY := resize(-MouseY, mouseIncX'length);
            else
               mouseIncX := to_signed(0, mouseIncX'length);
               mouseIncY := to_signed(0, mouseIncY'length);
            end if;

            newMouseAccX := mouseAccX + mouseIncX;
            newMouseAccY := mouseAccY + mouseIncY;

            if (newMouseAccX >= 255) then
                newMouseAccClippedX := to_signed(255, newMouseAccClippedX'length);
            elsif (newMouseAccX <= -256) then
                newMouseAccClippedX := to_signed(-256, newMouseAccClippedX'length);
            else
                newMouseAccClippedX := newMouseAccX;
            end if;

            if (newMouseAccY >= 255) then
                newMouseAccClippedY := to_signed(255, newMouseAccClippedY'length);
            elsif (newMouseAccY <= -256) then
                newMouseAccClippedY := to_signed(-256, newMouseAccClippedY'length);
            else
                newMouseAccClippedY := newMouseAccY;
            end if;

            mouseAccX <= newMouseAccClippedX;
            mouseAccY <= newMouseAccClippedY;
         
            if (portStates(portNr).dsRumbleMode = '1') then
               if (portStates(portNr).dsRumbleIndexS = -1) then portStates(portNr).rumble( 7 downto 0) <= (others => '0'); end if;
               if (portStates(portNr).dsRumbleIndexL = -1) then portStates(portNr).rumble(15 downto 8) <= (others => '0'); end if;
            end if;
         
            if (actionNext = '1' and transmitting = '1') then
               if (selected = '1' and joypad.PadPortEnable = '1') then
                  if (isActive = '0' and slotIdle = '1') then
                     if (controllerState = IDLE and transmitValue = x"01") then
                        controllerState <= READY;
                        isActive        <= '1';
                        ack             <= '1'; 
                        analogPadSave   <= joypad.PadPortAnalog;
                        mouseSave       <= joypad.PadPortMouse;
                        gunConSave      <= joypad.PadPortGunCon;
                        neGconSave      <= joypad.PadPortNeGcon;
                        justifSave      <= joypad.PadPortJustif;
                        dsSave          <= joypad.PadPortDS;
                        receiveValid    <= '1';
                        receiveBuffer   <= x"FF";
                        dsConfigModeSave  <= portStates(portNr).dsConfigMode;
                        dsAnalogModeSave  <= portStates(portNr).dsAnalogMode;
                     end if;
                  elsif (isActive = '1') then
                     case (controllerState) is
                        when IDLE => 
                           if (transmitValue = x"01") then
                              command         <= COMMAND_NONE;
                              controllerState <= READY;
                              isActive        <= '1';
                              ack             <= '1';
                              analogPadSave   <= joypad.PadPortAnalog;
                              mouseSave       <= joypad.PadPortMouse;
                              gunConSave      <= joypad.PadPortGunCon;
                              neGconSave      <= joypad.PadPortNeGcon;
                              justifSave      <= joypad.PadPortJustif;
                              dsSave          <= joypad.PadPortDS;
                              receiveValid    <= '1';
                              receiveBuffer   <= x"FF";
                              dsConfigModeSave  <= portStates(portNr).dsConfigMode;
                              dsAnalogModeSave  <= portStates(portNr).dsAnalogMode;
                           end if;
                           
-- ##############################################################################
-- #################### Common 
-- ##############################################################################
                           
                        when READY => 
                           if (transmitValue = x"42") then
                              command <= COMMAND_READ_INPUTS;
                              if (dsSave = '1' and dsConfigModeSave = '1') then
                                 receiveBuffer   <= x"F3";
                              elsif (mouseSave = '1') then
                                 receiveBuffer   <= x"12";
                              elsif (gunConSave = '1') then
                                 receiveBuffer   <= x"63";
                              elsif (neGconSave = '1') then
                                 receiveBuffer   <= x"23";
                              elsif (justifSave = '1') then
                                 receiveBuffer   <= x"31";
                              elsif (analogPadSave = '1' or dsAnalogModeSave = '1') then
                                 receiveBuffer   <= x"73";
                              else
                                 receiveBuffer   <= x"41";
                              end if;
                              controllerState <= ID;
                              ack             <= '1';
                              receiveValid    <= '1';
                           elsif (transmitValue = x"43") then
                              command <= COMMAND_CHANGE_CONFIG_MODE;
                              if (dsSave = '1') then
                                 if (dsConfigModeSave = '1') then
                                    receiveBuffer   <= x"F3";
                                 elsif (dsAnalogModeSave = '1') then
                                    receiveBuffer   <= x"73";
                                 else
                                    receiveBuffer   <= x"41";
                                 end if;
                                 controllerState <= ID;
                                 ack             <= '1';
                                 receiveValid    <= '1';
                              end if;
                           elsif (transmitValue = x"44") then
                              command <= COMMAND_SET_STATE;
                              if (dsSave = '1' and dsConfigModeSave = '1') then
                                 receiveBuffer   <= x"F3";
                                 controllerState <= ID;
                                 ack             <= '1';
                                 receiveValid    <= '1';
                                 portStates(portNr).dsRumbleConfig <= (others => '1');
                                 portStates(portNr).dsRumbleIndexS <= -1;
                                 portStates(portNr).dsRumbleIndexL <= -1;
                              end if;
                           elsif (transmitValue = x"45") then
                              command <= COMMAND_GET_STATE;
                              if (dsSave = '1' and dsConfigModeSave = '1') then
                                 receiveBuffer   <= x"F3";
                                 controllerState <= ID;
                                 ack             <= '1';
                                 receiveValid    <= '1';
                              end if;
                           elsif (transmitValue = x"46") then
                              command <= COMMAND_46;
                              if (dsSave = '1' and dsConfigModeSave = '1') then
                                 receiveBuffer   <= x"F3";
                                 controllerState <= ID;
                                 ack             <= '1';
                                 receiveValid    <= '1';
                              end if;
                           elsif (transmitValue = x"47") then
                              command <= COMMAND_47;
                              if (dsSave = '1' and dsConfigModeSave = '1') then
                                 receiveBuffer   <= x"F3";
                                 controllerState <= ID;
                                 ack             <= '1';
                                 receiveValid    <= '1';
                              end if;
                           elsif (transmitValue = x"4C") then
                              command <= COMMAND_4C;
                              if (dsSave = '1' and dsConfigModeSave = '1') then
                                 receiveBuffer   <= x"F3";
                                 controllerState <= ID;
                                 ack             <= '1';
                                 receiveValid    <= '1';
                              end if;
                           elsif (transmitValue = x"4D") then
                              command <= COMMAND_RUMBLE;
                              if (dsSave = '1' and dsConfigModeSave = '1') then
                                 receiveBuffer   <= x"F3";
                                 controllerState <= ID;
                                 ack             <= '1';
                                 receiveValid    <= '1';
                                 portStates(portNr).dsRumbleIndexS <= -1;
                                 portStates(portNr).dsRumbleIndexL <= -1;
                              end if;
                           else
                              controllerState <= IDLE;
                              command <= COMMAND_UNKNOWN;
                           end if;
                           
                        when ID => 
                           receiveBuffer   <= x"5A";
                           if (mouseSave = '1') then
                               controllerState <= MOUSEBUTTONSLSB;
                           elsif (gunConSave = '1') then
                               controllerState <= GUNCONBUTTONSLSB;
                           elsif (justifSave = '1') then
                               controllerState <= JUSTIFBUTTONSLSB;
                           else
                               controllerState <= BUTTONLSB;
                           end if;
                           
                           if (command = COMMAND_CHANGE_CONFIG_MODE and dsConfigModeSave = '1') then
                              controllerState <= CHANGECONFIG;
                           elsif (command = COMMAND_SET_STATE) then
                              controllerState <= SETSTATELSB;
                           elsif (command = COMMAND_46) then
                              controllerState <= COMMAND46;
                           elsif (command = COMMAND_47) then
                              controllerState <= COMMAND47;
                           elsif (command = COMMAND_4C) then
                              controllerState <= COMMAND4C;                           
                           elsif (command = COMMAND_RUMBLE) then
                              controllerState <= UPDATERUMBLE;
                              rumblecount     <= 0;
                           elsif (command = COMMAND_GET_STATE) then
                              rom_pointer     <= 6; 
                              bytecount       <= 2;
                              controllerState <= ROMRESPONSE; 
                              nextState       <= GETSTATE;
                           end if;

                           ack             <= '1';
                           receiveValid    <= '1';
                           
-- ##############################################################################
-- #################### Digital + Analog 
-- ##############################################################################

                        when BUTTONLSB => 
                           receiveBuffer(0) <= not joypad.KeySelect;
                           receiveBuffer(1) <= not joypad.KeyL3;
                           receiveBuffer(2) <= not joypad.KeyR3;
                           receiveBuffer(3) <= not joypad.KeyStart;
                           receiveBuffer(4) <= not joypad.KeyUp;
                           receiveBuffer(5) <= not joypad.KeyRight;
                           receiveBuffer(6) <= not joypad.KeyDown;
                           receiveBuffer(7) <= not joypad.KeyLeft;
                           if (neGconSave = '1') then
                              controllerState  <= NEGCONBUTTONMSB;
                           else
                              controllerState  <= BUTTONMSB;
                           end if;
                           ack              <= '1';
                           receiveValid     <= '1';
                           rumbleOnFirst    <= '0';
                           if (analogPadSave = '1' and (transmitValue(7) = '1' or  transmitValue(6) = '1')) then
                              rumbleOnFirst <= '1';
                           end if;

                           if (command = COMMAND_CHANGE_CONFIG_MODE) then
                              if (transmitValue = x"01") then
                                 portStates(portNr).dsConfigMode <= '1';
                              elsif (transmitValue = x"00") then
                                 portStates(portNr).dsConfigMode <= '0';
                              end if;
                           end if;
                           
                           if (portStates(portNr).dsRumbleMode = '1' and command = COMMAND_READ_INPUTS) then
                              if (portStates(portNr).dsRumbleIndexS = 0) then 
                                 portStates(portNr).rumble( 7 downto 0) <= x"00";
                                 if (transmitValue(0) = '1') then portStates(portNr).rumble(7 downto 0) <= x"FF"; end if;
                              end if;
                              if (portStates(portNr).dsRumbleIndexL = 0) then portStates(portNr).rumble(15 downto 8) <= transmitValue; end if;
                           end if;

                        when BUTTONMSB => 
                           receiveBuffer(0) <= not joypad.KeyL2;
                           receiveBuffer(1) <= not joypad.KeyR2;
                           receiveBuffer(2) <= not joypad.KeyL1;
                           receiveBuffer(3) <= not joypad.KeyR1;
                           receiveBuffer(4) <= not joypad.KeyTriangle;
                           receiveBuffer(5) <= not joypad.KeyCircle;
                           receiveBuffer(6) <= not joypad.KeyCross;
                           receiveBuffer(7) <= not joypad.KeySquare;
                           receiveValid     <= '1';
                           if (analogPadSave = '1' or dsAnalogModeSave = '1' or dsConfigModeSave = '1') then
                              controllerState <= ANALOGRIGHTX;
                              ack <= '1';
                           else
                              controllerState <= IDLE;
                           end if;
                           if (command = COMMAND_READ_INPUTS) then
                              if (portStates(portNr).dsRumbleMode = '1') then
                                 if (portStates(portNr).dsRumbleIndexS = 1) then 
                                    portStates(portNr).rumble( 7 downto 0) <= x"00";
                                    if (transmitValue(0) = '1') then portStates(portNr).rumble(7 downto 0) <= x"FF"; end if;
                                 end if;
                                 if (portStates(portNr).dsRumbleIndexL = 1) then portStates(portNr).rumble(15 downto 8) <= transmitValue; end if;
                              else
                                 portStates(portNr).rumble <= X"0000";
                                 if (analogPadSave = '1' and (transmitValue(0) = '1' or rumbleOnFirst = '1')) then
                                    portStates(portNr).rumble <= X"00FF";
                                 end if;
                              end if;
                           end if;
                           
                        when ANALOGRIGHTX => 
                           receiveBuffer   <= analogLarge;
                           if (joypad.WheelMap) then
                              receiveBuffer<= "10000000";
                           end if;
                           receiveValid    <= '1';
                           controllerState <= ANALOGRIGHTY;
                           ack             <= '1';
                           
                           if (portStates(portNr).dsRumbleMode = '1' and command = COMMAND_READ_INPUTS) then
                              if (portStates(portNr).dsRumbleIndexS = 2) then 
                                 portStates(portNr).rumble( 7 downto 0) <= x"00";
                                 if (transmitValue(0) = '1') then portStates(portNr).rumble(7 downto 0) <= x"FF"; end if;
                              end if;
                              if (portStates(portNr).dsRumbleIndexL = 2) then portStates(portNr).rumble(15 downto 8) <= transmitValue; end if;
                           end if;
                        
                        when ANALOGRIGHTY => 
                           receiveBuffer   <= analogLarge;
                           if (joypad.WheelMap) then
                              newPedal := (others => '0');
                              if (to_integer(joypad.Analog2Y) < 0) then
                                 newPedal := -joypad.Analog2Y;
                                 if (newPedal(7) = '1') then
                                    newPedal := "01111111"; -- workaround for -128
                                 end if;
                              end if;
                              if (to_integer(joypad.Analog1Y) < 0) then
                                 newPedal := newPedal + joypad.Analog1Y;
                              end if;
                              newPedal(7) := not newPedal(7);
                              receiveBuffer <= std_logic_vector(newPedal);
                           end if;
                           receiveValid    <= '1';
                           controllerState <= ANALOGLEFTX;
                           ack             <= '1';
                           
                           if (portStates(portNr).dsRumbleMode = '1' and command = COMMAND_READ_INPUTS) then
                              if (portStates(portNr).dsRumbleIndexS = 3) then 
                                 portStates(portNr).rumble( 7 downto 0) <= x"00";
                                 if (transmitValue(0) = '1') then portStates(portNr).rumble(7 downto 0) <= x"FF"; end if;
                              end if;
                              if (portStates(portNr).dsRumbleIndexL = 3) then portStates(portNr).rumble(15 downto 8) <= transmitValue; end if;
                           end if;
                        
                        when ANALOGLEFTX =>
                           receiveBuffer   <= analogLarge;
                           if (joypad.WheelMap) then
                              receiveBuffer<= std_logic_vector(to_unsigned(to_integer(joypad.Analog1X) + 128, 8));
                           end if;
                           receiveValid    <= '1';
                           controllerState <= ANALOGLEFTY;
                           ack             <= '1';
                           
                           if (portStates(portNr).dsRumbleMode = '1' and command = COMMAND_READ_INPUTS) then
                              if (portStates(portNr).dsRumbleIndexS = 4) then 
                                 portStates(portNr).rumble( 7 downto 0) <= x"00";
                                 if (transmitValue(0) = '1') then portStates(portNr).rumble(7 downto 0) <= x"FF"; end if;
                              end if;
                              if (portStates(portNr).dsRumbleIndexL = 4) then portStates(portNr).rumble(15 downto 8) <= transmitValue; end if;
                           end if;
                        
                        when ANALOGLEFTY =>
                           receiveBuffer   <= analogLarge;
                           if (joypad.WheelMap) then
                              receiveBuffer<= "10000000";
                           end if;
                           receiveValid    <= '1';
                           controllerState <= IDLE;
                           
                           if (portStates(portNr).dsRumbleMode = '1' and command = COMMAND_READ_INPUTS) then
                              if (portStates(portNr).dsRumbleIndexS = 5) then 
                                 portStates(portNr).rumble( 7 downto 0) <= x"00";
                                 if (transmitValue(0) = '1') then portStates(portNr).rumble(7 downto 0) <= x"FF"; end if;
                              end if;
                              if (portStates(portNr).dsRumbleIndexL = 5) then portStates(portNr).rumble(15 downto 8) <= transmitValue; end if;
                           end if;
                           
-- ##############################################################################
-- #################### Mouse 
-- ##############################################################################

                        when MOUSEBUTTONSLSB =>
                           controllerState <= MOUSEBUTTONSMSB;
                           receiveBuffer   <= x"FF";
                           ack             <= '1';
                           receiveValid    <= '1';
                           
                           if (mouseAccX >= 127) then
                               mouseOutX <= to_signed(127, mouseOutX'length);
                           elsif (mouseAccX <= -128) then
                               mouseOutX <= to_signed(-128, mouseOutX'length);
                           else
                               mouseOutX <= resize(mouseAccX, mouseOutX'length);
                           end if;

                           if (mouseAccY >= 127) then
                               mouseOutY <= to_signed(127, mouseOutY'length);
                           elsif (mouseAccY <= -128) then
                               mouseOutY <= to_signed(-128, mouseOutY'length);
                           else
                               mouseOutY <= resize(mouseAccY, mouseOutY'length);
                           end if;

                           mouseAccX <= mouseIncX;
                           mouseAccY <= mouseIncY;
                           

                        when MOUSEBUTTONSMSB =>
                           receiveBuffer(0) <= '0';
                           receiveBuffer(1) <= '0';
                           receiveBuffer(2) <= not MouseRight;
                           receiveBuffer(3) <= not MouseLeft;
                           receiveBuffer(4) <= '1';
                           receiveBuffer(5) <= '1';
                           receiveBuffer(6) <= '1';
                           receiveBuffer(7) <= '1';
                           controllerState  <= MOUSEAXISX;
                           ack              <= '1';
                           receiveValid     <= '1';

                        when MOUSEAXISX =>
                           receiveBuffer   <= std_logic_vector(mouseOutX);
                           receiveValid    <= '1';
                           controllerState <= MOUSEAXISY;
                           ack             <= '1';

                        when MOUSEAXISY =>
                           receiveBuffer   <= std_logic_vector(mouseOutY);
                           receiveValid    <= '1';
                           controllerState <= IDLE;
                           
-- ##############################################################################
-- #################### GunCon 
-- ##############################################################################

                        when GUNCONBUTTONSLSB =>
                           controllerState <= GUNCONBUTTONSMSB;
                           ack             <= '1';
                           receiveValid    <= '1';

                           if joypad.KeyTriangle = '1' or GunAimOffscreen = '1' then
                              gunOffscreen <= '1';
                           else
                              gunOffscreen <= '0';
                           end if;

                           receiveBuffer(0) <= '1';
                           receiveBuffer(1) <= '1';
                           receiveBuffer(2) <= '1';
                           receiveBuffer(3) <= not joypad.KeyStart; -- A (left-side button)
                           receiveBuffer(4) <= '1';
                           receiveBuffer(5) <= '1';
                           receiveBuffer(6) <= '1';
                           receiveBuffer(7) <= '1';

                        when GUNCONBUTTONSMSB =>
                           controllerState  <= GUNCONXLSB;
                           ack              <= '1';
                           receiveValid     <= '1';

                           -- GunCon reports X as # of 8MHz clks since HSYNC (01h=Error, or 04Dh..1CDh).
                           -- Map from joystick's +/-128 to GunCon range (8MHz clocks): (GunX * 384/256) + 67
                           if gunOffscreen = '0' then
                              gunConX_8MHz  <= std_logic_vector(to_unsigned(67, 9) + resize(GunX, 9) + resize(GunX(7 downto 1), 9) );
                           else
                              gunConX_8MHz  <= "000000001"; -- X: 0x0001, Y: 0x000A indicates no light / offscreen shot
                           end if;

                           receiveBuffer(0) <= '1';
                           receiveBuffer(1) <= '1';
                           receiveBuffer(2) <= '1';
                           receiveBuffer(3) <= '1';
                           receiveBuffer(4) <= '1';
                           receiveBuffer(5) <= not (joypad.KeyCircle or joypad.KeyTriangle); -- Trigger
                           receiveBuffer(6) <= not joypad.KeyCross; -- B (right-side button)
                           receiveBuffer(7) <= '1';

                        when GUNCONXLSB =>
                           controllerState <= GUNCONXMSB;
                           receiveValid    <= '1';
                           ack             <= '1';

                           receiveBuffer   <= gunConX_8MHz(7 downto 0);

                        when GUNCONXMSB =>
                           controllerState <= GUNCONYLSB;
                           receiveValid    <= '1';
                           ack             <= '1';

                           -- GunCon reports Y as # of scanlines since VSYNC (05h/0Ah=Error, PAL=20h..127h, NTSC=19h..F8h)
                           if gunOffscreen = '0' then
                              if isPal = '1' then
                                 gunConY      <= std_logic_vector(to_unsigned(40, 9) + GunY_scanlines);
                              else
                                 gunConY      <= std_logic_vector(to_unsigned(16, 9) + GunY_scanlines);
                              end if;
                           else
                              gunConY      <= "000001010"; -- X: 0x0001, Y: 0x000A indicates no light / offscreen shot
                           end if;

                           receiveBuffer   <= "0000000" & gunConX_8MHz(8);

                        when GUNCONYLSB =>
                           controllerState <= GUNCONYMSB;
                           receiveValid    <= '1';
                           ack             <= '1';

                           receiveBuffer   <= gunConY(7 downto 0);

                        when GUNCONYMSB =>
                           controllerState <= IDLE;
                           receiveValid    <= '1';

                           receiveBuffer   <= "0000000" & gunConY(8);

                           
-- ##############################################################################
-- #################### NegCon 
-- ##############################################################################

                        when NEGCONBUTTONMSB =>
                           -- 0 0 0 R1 B A 0 0
                           receiveBuffer(0) <= '1'; -- NeGcon does not report
                           receiveBuffer(1) <= '1'; -- NeGcon does not report
                           receiveBuffer(2) <= '1'; -- NeGcon does not report
                           receiveBuffer(3) <= not joypad.KeyR1;
                           receiveBuffer(4) <= not joypad.KeyTriangle;
                           receiveBuffer(5) <= not joypad.KeyCircle;
                           receiveBuffer(6) <= '1'; -- NeGcon does not report
                           receiveBuffer(7) <= '1'; -- NeGcon does not report
                           receiveValid     <= '1';
                           controllerState <= NEGCONSTEERING;
                           ack <= '1';

                        when NEGCONSTEERING =>
                           -- Same as ANALOGLEFTX, use IF in there to go to NEGCONANALOGI?
                           receiveBuffer   <= std_logic_vector(to_unsigned(to_integer(joypad.Analog1X) + 128, 8));
                           receiveValid    <= '1';
                           controllerState <= NEGCONANALOGI;
                           ack             <= '1';

                        when NEGCONANALOGI =>
                           receiveBuffer   <= "00000000";
                           if (joypad.KeyCross = '1' or joypad.KeyR2 = '1') then
                              -- Buttons are Buttons and full throttle
                              receiveBuffer   <= "11111111";
                           elsif (joypad.WheelMap) then
                              if (to_integer(joypad.Analog1Y) < 0) then
                                 receiveBuffer   <= std_logic_vector(1 + shift_left(not to_unsigned(to_integer(joypad.Analog1Y),8),1));
                              end if;
                           elsif ( to_integer(joypad.Analog2Y) < 0) then
                              -- Buttons are right stick up
                              -- Due to half resolution of the stick its range of -128 to 1 is mapped to 0x03 to 0xFF
                              receiveBuffer   <= std_logic_vector(1 + shift_left(not to_unsigned(to_integer(joypad.Analog2Y),8),1));
                           else
                              receiveBuffer   <= "00000000";
                           end if;
                           receiveValid    <= '1';
                           controllerState <= NEGCONANALOGII;
                           ack             <= '1';

                        when NEGCONANALOGII =>
                           receiveBuffer   <= "00000000";
                           if (joypad.KeySquare = '1' or joypad.KeyL2 = '1') then
                              -- Buttons are Buttons and full throttle
                              receiveBuffer   <= "11111111";
                           elsif (joypad.WheelMap) then
                              if (to_integer(joypad.Analog2Y) < 0) then
                                 receiveBuffer   <= std_logic_vector(1 + shift_left(not to_unsigned(to_integer(joypad.Analog2Y),8),1));
                              end if;
                           elsif ( to_integer(joypad.Analog2Y) > 0) then
                              -- Buttons are right stick down
                              -- Due to half resolution of the stick its range of 1 to 127 is mapped to 0x03 to 0xFF
                              receiveBuffer   <= std_logic_vector(1 + shift_left(to_unsigned(to_integer(joypad.Analog2Y),8),1));
                           else
                              receiveBuffer   <= "00000000";
                           end if;
                           receiveValid    <= '1';
                           controllerState <= NEGCONANALOGL;
                           ack             <= '1';

                        when NEGCONANALOGL =>
                           -- Ran out of analog buttons, ideally analog triggers would be supported and a layout
                           -- R2->I, L2->II, AnalogR->L would be possible, enabling I/II being independent when analog and have analog L
                           receiveBuffer   <= "00000000";
                           if (joypad.KeyL1 = '1') then
                              receiveBuffer   <= "11111111";
                           elsif (joypad.WheelMap) then
                              if (to_integer(joypad.Analog2X) < 0) then
                                 receiveBuffer   <= std_logic_vector(1 + shift_left(not to_unsigned(to_integer(joypad.Analog2X),8),1));
                           end if;
                           end if;
                           receiveValid    <= '1';
                           controllerState <= IDLE;

-- ##############################################################################
-- #################### Konami Justifier
-- ##############################################################################

                        when JUSTIFBUTTONSLSB =>
                           controllerState <= JUSTIFBUTTONSMSB;
                           ack             <= '1';
                           receiveValid    <= '1';

                           if joypad.KeyTriangle = '1' or GunAimOffscreen = '1' then
                              gunOffscreen <= '1';
                           else
                              gunOffscreen <= '0';
                           end if;

                           receiveBuffer(0) <= '1';
                           receiveBuffer(1) <= '1';
                           receiveBuffer(2) <= '1';
                           receiveBuffer(3) <= not joypad.KeyStart; -- Start (left-side button)
                           receiveBuffer(4) <= '1';
                           receiveBuffer(5) <= '1';
                           receiveBuffer(6) <= '1';
                           receiveBuffer(7) <= '1';

                        when JUSTIFBUTTONSMSB =>
                           controllerState  <= IDLE;
                           receiveValid     <= '1';

                           receiveBuffer(0) <= '1';
                           receiveBuffer(1) <= '1';
                           receiveBuffer(2) <= '1';
                           receiveBuffer(3) <= '1';
                           receiveBuffer(4) <= '1';
                           receiveBuffer(5) <= '1';
                           receiveBuffer(6) <= not joypad.KeyCross; -- Back (rear-end button)
                           receiveBuffer(7) <= not (joypad.KeyCircle or joypad.KeyTriangle); -- Trigger

                           
-- ##############################################################################
-- #################### Dualshock 
-- ##############################################################################
                           
                        when CHANGECONFIG =>
                           receiveValid    <= '1';
                           receiveBuffer   <= x"00";
                           ack             <= '1';
                           portStates(portNr).dsRumbleMode <= '1';
                           if (transmitValue = x"01") then
                              portStates(portNr).dsConfigMode <= '1';
                           elsif (transmitValue = x"00") then
                              portStates(portNr).dsConfigMode <= '0';
                           end if;
                           rom_pointer     <= 0; 
                           bytecount       <= 5;
                           controllerState <= ROMRESPONSE; 
                           nextState       <= IDLE;

                        when SETSTATELSB =>
                           if (transmitValue = x"00") then
                              portStates(portNr).dsAnalogMode<= '0';
                           elsif  (transmitValue = x"01") then
                              portStates(portNr).dsAnalogMode<= '1';
                           end if;
                           receiveValid    <= '1';
                           receiveBuffer   <= x"00";
                           ack             <= '1';
                           controllerState <= SETSTATEMSB;

                        when SETSTATEMSB =>
                           if (transmitValue = x"02") then
                              portStates(portNr).dsAnalogLock <= '0';
                           elsif (transmitValue = x"03") then
                              portStates(portNr).dsAnalogLock <= '1';
                           end if;
                           receiveValid    <= '1';
                           receiveBuffer   <= x"00";
                           ack             <= '1';
                           rom_pointer     <= 0; 
                           bytecount       <= 4;
                           controllerState <= ROMRESPONSE; 
                           nextState       <= IDLE;

                        when GETSTATE =>
                           if (dsAnalogModeSave = '1') then
                              receiveBuffer   <= x"01";
                           else
                              receiveBuffer   <= x"00";
                           end if;
                           receiveValid    <= '1';
                           ack             <= '1';
                           rom_pointer     <= 8; 
                           bytecount       <= 3;
                           controllerState <= ROMRESPONSE; 
                           nextState       <= IDLE;

                        when COMMAND46 =>
                           receiveValid    <= '1';
                           ack             <= '1';
                           if (transmitValue = x"00") then
                              rom_pointer <= 11;
                           elsif (transmitValue = x"01") then
                              rom_pointer <= 16;
                           else
                              rom_pointer <= 0;
                           end if;
                           bytecount       <= 5;
                           controllerState <= ROMRESPONSE; 
                           nextState       <= IDLE;

                        when COMMAND47 =>
                           receiveValid    <= '1';
                           receiveBuffer   <= x"00";
                           ack             <= '1';
                           if (transmitValue = x"00") then
                              rom_pointer <= 21;
                           else
                              rom_pointer <= 0;
                           end if;
                           bytecount       <= 5;
                           controllerState <= ROMRESPONSE; 
                           nextState       <= IDLE;

                        when COMMAND4C =>
                           receiveValid    <= '1';
                           receiveBuffer   <= x"00";
                           ack             <= '1';
                           if (transmitValue = x"00") then
                              rom_pointer <= 26;
                           elsif (transmitValue = x"01") then
                              rom_pointer <= 31;
                           else
                              rom_pointer <= 0;
                           end if;
                           bytecount       <= 5;
                           controllerState <= ROMRESPONSE; 
                           nextState       <= IDLE;

                        when UPDATERUMBLE =>
                           receiveValid    <= '1';
                           receiveBuffer   <= portStates(portNr).dsRumbleConfig(((8 * rumblecount) + 7) downto (8 * rumblecount));
                           portStates(portNr).dsRumbleConfig(((8 * rumblecount) + 7) downto (8 * rumblecount)) <= transmitValue;
                           
                           if (transmitValue = x"00") then 
                              portStates(portNr).dsRumbleIndexS <= rumblecount;
                           end if;
                           
                           if (transmitValue = x"01") then 
                              portStates(portNr).dsRumbleIndexL <= rumblecount;
                           end if;
                           
                           if (rumblecount < 5) then
                              rumblecount <= rumblecount + 1;
                              ack         <= '1';
                           else
                              controllerState <= IDLE;
                           end if;

                        when ROMRESPONSE =>
                           if (bytecount > 0) then
                              receiveBuffer   <= response(rom_pointer);
                              receiveValid    <= '1';
                              bytecount <= bytecount - 1;
                              rom_pointer <= rom_pointer + 1;
                              ack <= '1';
                           else
                              nextState <= IDLE; -- we shouldn't normally get here
                           end if;

                           if (bytecount = 1) then -- last byte, prepare next state
                              nextState <= IDLE;
                              controllerState <= nextState;
                              if (nextState = IDLE) then
                                 ack <= '0';
                              end if;
                           end if;

                     end case;
                  end if;
               end if; -- joy select
               
            end if; -- transmit
            
         end if; -- ce
      end if; -- clock
   end process;
   
   
end architecture;





