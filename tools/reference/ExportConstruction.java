import com.google.gson.Gson;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.item.BlockItem;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.ItemLike;
import net.minecraft.world.item.CreativeModeTab;
import net.minecraft.world.level.EmptyBlockGetter;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.Property;
import net.minecraft.world.phys.shapes.VoxelShape;

/** Offline developer tool. Read the pinned vanilla registry; never boot a server or touch a world. */
public final class ExportConstruction {
    private static final EmptyBlockGetter WORLD = EmptyBlockGetter.INSTANCE;
    private static final BlockPos POS = BlockPos.ZERO;
    private static final Map<List<List<Double>>,Integer> shapes = new LinkedHashMap<>();
    private static int shape(VoxelShape shape) {
        var boxes = shape.toAabbs().stream().map(b -> List.of(b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ)).toList();
        return shapes.computeIfAbsent(boxes, key -> shapes.size());
    }
    private static <T extends Comparable<T>> String value(BlockState state, Property<T> p) {
        return p.getName(state.getValue(p));
    }
    private static Map<String,String> props(BlockState s) {
        var values = new TreeMap<String,String>();
        for (var p : s.getProperties()) values.put(p.getName(),value(s,p));
        return values;
    }
    public static void main(String[] args) throws Exception {
        SharedConstants.tryDetectVersion();
        Bootstrap.bootStrap();
        var blocks = new LinkedHashMap<String,Object>();
        var tabs = new LinkedHashMap<String,List<String>>();
        for (String tabName : List.of("building_blocks","colored_blocks")) {
            var tab = BuiltInRegistries.CREATIVE_MODE_TAB.getValue(Identifier.withDefaultNamespace(tabName));
            // Observe item identities before stack construction; the static data exporter
            // has no datapack-bound component registry and needs no inventory instance.
            var field = CreativeModeTab.class.getDeclaredField("displayItemsGenerator");
            field.setAccessible(true);
            var items = new ArrayList<ItemLike>();
            var output = Class.forName("net.minecraft.world.item.CreativeModeTab$Output");
            var sink = java.lang.reflect.Proxy.newProxyInstance(output.getClassLoader(),new Class<?>[]{output},
                (proxy,method,values) -> {
                    if (values[0] instanceof ItemLike item) items.add(item);
                    else if (values[0] instanceof ItemStack stack) items.add(stack.getItem());
                    else throw new IllegalArgumentException(method.toString());
                    return null;
                });
            field.getType().getMethod("accept",CreativeModeTab.ItemDisplayParameters.class,output)
                .invoke(field.get(tab), new CreativeModeTab.ItemDisplayParameters(FeatureFlags.DEFAULT_FLAGS,false,null),sink);
            var order = new ArrayList<String>();
            for (var item : items) {
                if (!(item.asItem() instanceof BlockItem bi)) {
                    if (tabName.equals("colored_blocks")) continue;
                    throw new IllegalArgumentException(item.toString());
                }
                Block block = bi.getBlock();
                String id = BuiltInRegistries.BLOCK.getKey(block).getPath();
                if (tabName.equals("colored_blocks") && !id.matches(".*(?:wool|carpet|terracotta|concrete|concrete_powder|stained_glass|stained_glass_pane)(?:_stairs|_slab|_wall)?$|glass|glass_pane")) continue;
                order.add(id);
                if (blocks.containsKey(id)) continue;
                var d = block.defaultBlockState();
                var row = new LinkedHashMap<String,Object>();
                row.put("class",block.getClass().getSimpleName());
                row.put("default",props(d));
                row.put("hardness",d.getDestroySpeed(WORLD,POS));
                row.put("resistance",block.getExplosionResistance());
                row.put("requires_tool",d.requiresCorrectToolForDrops());
                row.put("push",d.getPistonPushReaction().toString().toLowerCase(Locale.ROOT));
                row.put("sound",List.of(d.getSoundType().getBreakSound().location().getPath(),d.getSoundType().getHitSound().location().getPath(),d.getSoundType().getPlaceSound().location().getPath()));
                var states = new LinkedHashMap<String,Object>();
                for (var s : block.getStateDefinition().getPossibleStates()) {
                    String key = String.join(",", props(s).values());
                    states.put(key,List.of(shape(s.getCollisionShape(WORLD,POS)),shape(s.getShape(WORLD,POS)),
                        s.getLightEmission(),s.isSolidRender(),s.isRedstoneConductor(WORLD,POS)));
                }
                row.put("states",states);
                blocks.put(id,row);
            }
            tabs.put(tabName,order);
        }
        Files.writeString(Path.of(args[0]),new Gson().toJson(Map.of("blocks",blocks,"tabs",tabs,"shapes",shapes.keySet())));
    }
}
